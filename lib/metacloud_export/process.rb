class MetacloudExport::Process

  DEFAULT_AUTHN_DRIVER = ::OpenNebula::User::X509_AUTH || "x509"

  def initialize(source, target, logger)
    parsed = JSON.parse(source.read)
    @source = Hashie::Mash.new({ :users => parsed })

    @endpoint = target.endpoint.to_s
    secret = "#{target.username}:#{target.password}"
    @client = ::OpenNebula::Client.new(secret, @endpoint)

    @logger = logger

    @user_pool = self.class.user_pool(@client, @logger)
    @group_pool = self.class.group_pool(@client, @logger)
  end

  def run
    perun_groups = perun_group_names(@source.users)
    one_groups = existing_group_names

    check_groups(one_groups, perun_groups)

    perun_users = @source.users.collect { |p_user| p_user.login }
    one_users = existing_user_names(perun_groups)

    @logger.info "Clean-up of old ONE accounts"
    one_users.each do |one_user|
      remove_user(one_user) unless perun_users.include?(one_user)
    end

    @logger.info "Adding/Updating ONE accounts"
    @source.users.each do |perun_user|
      check_user(perun_user)

      if one_users.include?(perun_user.login)
        update_user(perun_user)
      else
        add_user(perun_user)
      end
    end
  end

  private

  def existing_group_names
    @logger.debug "Getting group names from GroupPool"
    groups = []

    @group_pool.each { |group| groups << group['NAME'] }

    @logger.debug "Group names: #{groups.to_s}"
    groups
  end

  def existing_user_names(perun_groups)
    @logger.debug "Getting user names for #{perun_groups.to_s} from UserPool"
    users = []

    @user_pool.each do |user| 
      rest = user_group_names(user) - perun_groups
      users << user['NAME'] if rest.empty?
    end

    @logger.debug "User names: #{users.to_s}"
    users
  end

  def user_group_names(user)
    @logger.debug "Getting group names for #{user['NAME'].inspect}"
    group_names = []

    user.each_xpath("GROUPS/ID") do |gid|
      group_names << gid_to_gname(gid)
    end

    @logger.debug "Group names: #{group_names.to_s}"
    group_names
  end

  def gid_to_gname(gid)
    @logger.debug "Getting a name for GID #{gid.inspect}"
    gname = nil

    @group_pool.each do |group|
      if group['ID'].to_i == gid.to_i
        gname = group['NAME']
        break
      end
    end
    raise "GID #{gid.inspect} not found!" unless gname

    @logger.debug "Group name: #{gname.inspect}"
    gname
  end

  def gname_to_gid(gname)
    @logger.debug "Getting a GID for #{gname.inspect}"
    gid = nil

    @group_pool.each do |group|
      if group['NAME'] == gname
        gid = group['ID']
        break
      end
    end
    raise "GNAME #{gname.inspect} not found!" unless gid

    @logger.debug "GID: #{gid.inspect}"
    gid
  end

  def perun_group_names(perun_users)
    @logger.debug "Getting group names from Perun"
    perun_groups = perun_users.collect { |p_user| p_user.groups }
    perun_groups.flatten!
    perun_groups.uniq!

    @logger.debug "Group names: #{perun_groups.to_s}"
    perun_groups
  end

  def check_groups(one_groups, perun_groups)
    @logger.debug "Checking groups from Perun against ONE groups: #{one_groups.to_s}"
    @logger.debug "Perun groups: #{perun_groups.to_s}"

    if perun_groups.include?('oneadmin') || perun_groups.include?('users')
      raise "Group #{p_group.inspect} is not allowed!"
    end

    perun_groups.each do |p_group|
      raise "Group #{p_group.inspect} is not allowed!" unless one_groups.include?(p_group)
    end
  end

  def check_user(perun_user)
    @logger.debug "Checking user #{perun_user.login.inspect} from Perun"

    if perun_user.login.include?('oneadmin') || perun_user.login.include?('serveradmin')
      raise "User #{perun_user.login.inspect} is not allowed!"
    end

    if perun_user.groups.empty?
      raise "User #{perun_user.login.inspect} is not a member of any group!"
    end

    if perun_user.krb_principals.empty? || perun_user.cert_dns.empty?
      raise "User #{perun_user.login.inspect} doesn't have required credentials!"
    end
  end

  def add_user(user_data)
    @logger.info "Creating user #{user_data.login.inspect} in ONE"

    password = user_creds_to_passwd(user_data)

    @logger.debug "With passwd: #{password.inspect}"
    user = ::OpenNebula::User.new(::OpenNebula::User.build_xml, @client)
    rc = user.allocate(user_data.login, password, DEFAULT_AUTHN_DRIVER)
    self.class.check_retval(rc)

    # groups
    user_set_groups(user, user_data.groups)

    # TODO: properties
  end

  def user_set_groups(user, groups)
    @logger.info "Setting grp: #{user_data.groups.first.inspect}"
    primary_grp = groups.first
    rc = user.chgrp(gname_to_gid(primary_grp))
    self.class.check_retval(rc)

    groups.each do |grp|
      next if grp == primary_grp
      @logger.debug "Also adding grp: #{grp.inspect}"
      rc = user.addgroup(gname_to_gid(grp))
      self.class.check_retval(rc)
    end
  end

  def user_creds_to_passwd(user_data)
    password = []

    password << user_data.krb_principals.join('|')
    password << user_data.cert_dns.join('|')
    password = password.join('|')

    password
  end

  def update_user(user_data)
    @logger.info "Updating user #{user_data.login.inspect} in ONE"
    one_user = uname_to_data(user_data.login)

    # auth driver
    if one_user['AUTH_DRIVER'] != DEFAULT_AUTHN_DRIVER
      @logger.debug "Changing AUTH_DRIVER from #{one_user['AUTH_DRIVER'].inspect} to #{DEFAULT_AUTHN_DRIVER.inspect}"
      rc = one_user.chauth(DEFAULT_AUTHN_DRIVER)
      self.class.check_retval(rc)
    end

    # passwd
    pw = user_creds_to_passwd(user_data)
    if one_user['PASSWORD'] != pw
      @logger.debug "Changing PASSWD from #{one_user['PASSWORD'].inspect} to #{pw.inspect}"
      rc = one_user.passwd(pw)
      self.class.check_retval(rc)
    end

    # add groups
    user_set_groups(one_user, user_data.groups)

    # del groups
    one_grps = user_group_names(one_user)
    grps_to_del = one_grps - user_data.groups
    user_del_groups(one_user, grps_to_del)

    # TODO: properties
  end

  def user_del_groups(user, groups)
    @logger.info "Deleting groups for #{user['NAME'].inspect}"
    @logger.debug "Del. groups: #{groups.to_s}"
    groups.each do |del_group|
      rc = user.delgroup(gname_to_gid(del_group))
      self.class.check_retval(rc)
    end
  end

  def user_set_properties(user_data)
    # TODO
  end

  def remove_user(username)
    @logger.debug "Removing user #{username.inspect} from ONE"
    if username.include?('oneadmin')
      raise "Cannot remove #{username.inspect}!"
    end

    user_data = uname_to_data(username)
    user_groups = user_group_names(user_data)
    if user_groups.include?('oneadmin') || user_groups.include?('users')
      raise "Cannot remove #{username.inspect}! It's a member of 'oneadmin' or 'users' group."
    end

    kill_vms(user_data['ID'])
    remove_images(user_data['ID'])
    remove_networks(user_data['ID'])

    rc = user_data.delete
    self.class.check_retval(rc)
  end

  def uname_to_data(username)
    @logger.debug "Getting an object for #{username.inspect}"
    user = nil

    @user_pool.each do |one_user|
      if one_user['NAME'] == username
        user = one_user
        break
      end
    end
    raise "UNAME #{username.inspect} is not found!" unless user

    user
  end

  def kill_vms(uid)
    # TODO
  end

  def remove_images(uid)
    # TODO
  end

  def remove_networks(uid)
    # TODO
  end

  class << self

    def user_pool(client, logger)
      logger.debug "Getting UserPool"
      user_pool = ::OpenNebula::UserPool.new(client)
      rc = user_pool.info
      check_retval(rc)

      user_pool
    end

    def group_pool(client, logger)
      logger.debug "Getting GroupPool"
      group_pool = ::OpenNebula::GroupPool.new(client)
      rc = group_pool.info
      check_retval(rc)

      group_pool
    end

    def check_retval(rc)
      raise rc.message if ::OpenNebula.is_error?(rc)
    end

  end

end
