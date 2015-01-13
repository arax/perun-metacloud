class MetacloudExport::Process

  DEFAULT_AUTHN_DRIVER = ::OpenNebula::User::X509_AUTH || "x509"
  EXCLUDED_ONE_GROUPS = ['oneadmin', 'devel'].freeze
  NO_ADD_GROUPS = (EXCLUDED_ONE_GROUPS + ['users']).freeze

  def initialize(source, target, logger)
    parsed = JSON.parse(source.read)
    @source = Hashie::Mash.new({ :users => parsed })

    @endpoint = target.endpoint.to_s
    secret = "#{target.username}:#{target.password}"
    @client = ::OpenNebula::Client.new(secret, @endpoint)

    @logger = logger

    @user_pool = self.class.user_pool(@client, @logger)
    @group_pool = self.class.group_pool(@client, @logger)
    @vm_pool = self.class.vm_pool(@client, @logger)
  end

  def run
    @logger.info "Starting propagation"
    perun_groups = perun_group_names(@source.users)
    managed_groups = existing_group_names(EXCLUDED_ONE_GROUPS)

    check_groups(managed_groups, perun_groups)

    perun_users = @source.users.collect { |p_user| p_user.login }
    one_users = existing_user_names(managed_groups)

    @logger.info "Clean-up of old ONE accounts"
    one_users.each do |one_user|
      unless perun_users.include?(one_user)
        @logger.info "Deleting user #{one_user.inspect} from ONE"
        remove_user(one_user)
      end
    end

    @logger.info "Adding/Updating ONE accounts"
    @source.users.each do |perun_user|
      check_user(perun_user)

      if one_users.include?(perun_user.login)
        @logger.info "Updating user #{perun_user.login.inspect} in ONE"
        update_user(perun_user)
      else
        @logger.info "Creating user #{perun_user.login.inspect} in ONE"
        add_user(perun_user)
      end
    end

    @logger.info "Propagation finished"
  end

  private

  def existing_group_names(excl)
    groups = []

    @group_pool.each { |group|
      groups << group['NAME'] unless excl.include?(group['NAME'])
    }

    @logger.debug "Getting existing groups in ONE whilst excluding #{excl.to_s}: #{groups.to_s}"
    groups
  end

  def existing_user_names(managed_groups)
    users = []

    @user_pool.each do |user|
      rest = user_group_names(user) - managed_groups
      users << user['NAME'] if rest.empty?
    end

    @logger.debug "Getting existing users in ONE, from Perun-managed " \
                  "groups #{managed_groups.to_s}: #{users.to_s}"
    users
  end

  def user_group_names(user)
    group_names = []

    user.each_xpath("GROUPS/ID") do |gid|
      group_names << gid_to_gname(gid.to_i)
    end

    @logger.debug "ONE groups for user #{user['NAME'].inspect}: #{group_names.to_s}"
    group_names
  end

  def gid_to_gname(gid)
    gname = nil

    @group_pool.each do |group|
      if group['ID'].to_i == gid.to_i
        gname = group['NAME']
        break
      end
    end
    raise "GID #{gid.inspect} not found!" unless gname

    @logger.debug "GID[#{gid.inspect}] has been recognized as GNAME[#{gname.inspect}]"
    gname
  end

  def gname_to_gid(gname)
    gid = nil

    @group_pool.each do |group|
      if group['NAME'] == gname
        gid = group['ID'].to_i
        break
      end
    end
    raise "GNAME #{gname.inspect} not found!" unless gid

    @logger.debug "GNAME[#{gname.inspect}] has been resolved to GID[#{gid.inspect}]"
    gid
  end

  def perun_group_names(perun_users)
    perun_groups = perun_users.collect { |p_user| p_user.groups }
    perun_groups.flatten!
    perun_groups.uniq!

    @logger.debug "Getting all user groups from Perun: #{perun_groups.to_s}"
    perun_groups
  end

  def check_groups(one_groups, perun_groups)
    unless (perun_groups & NO_ADD_GROUPS).empty?
      raise "A group in #{perun_groups.to_s} is not allowed!"
    end

    perun_groups.each do |p_group|
      raise "Group #{p_group.inspect} is not allowed!" unless one_groups.include?(p_group)
    end
  end

  def check_user(perun_user)
    @logger.debug "Validating user #{perun_user.login.inspect} from Perun"

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
    password = user_creds_to_passwd(user_data)

    @logger.debug "Creating #{user_data.login.inspect} with passwd: #{password.inspect}"
    user = ::OpenNebula::User.new(::OpenNebula::User.build_xml, @client)
    rc = user.allocate(user_data.login, password, DEFAULT_AUTHN_DRIVER)
    self.class.check_retval(rc, @logger)

    # refresh local cache
    rc = user.info
    self.class.check_retval(rc, @logger)

    # groups
    user_set_groups(user, user_data.groups)

    # properties
    user_set_properties(user, user_data)
  end

  def user_set_groups(user, groups)
    primary_grp = user['GNAME']

    unless groups.include?(primary_grp)
      primary_grp = groups.first
      @logger.debug "Adding #{user['NAME'].inspect} to primary group #{primary_grp.inspect}"

      rc = user.chgrp(gname_to_gid(primary_grp))
      self.class.check_retval(rc, @logger)
    end

    groups.each do |grp|
      next if grp == primary_grp

      @logger.debug "Adding #{user['NAME'].inspect} to secondary group #{grp.inspect}"
      rc = user.addgroup(gname_to_gid(grp))

      if ::OpenNebula::is_error?(rc)
        unless rc.message.include?('User is already in this group')
          self.class.check_retval(rc, @logger)
        end
      end
    end
  end

  def user_creds_to_passwd(user_data)
    password = []

    password << user_data.krb_principals.join('|')
    password << user_data.cert_dns.join('|')
    password = password.join('|')

    self.class.escape_dn(password)
  end

  def update_user(user_data)
    one_user = uname_to_data(user_data.login)

    # auth driver
    if one_user['AUTH_DRIVER'] != DEFAULT_AUTHN_DRIVER
      @logger.debug "Changing AUTH_DRIVER of #{one_user['NAME'].inspect} " \
                    "from #{one_user['AUTH_DRIVER'].inspect} to #{DEFAULT_AUTHN_DRIVER.inspect}"
      rc = one_user.chauth(DEFAULT_AUTHN_DRIVER)
      self.class.check_retval(rc, @logger)
    end

    # passwd
    pw = user_creds_to_passwd(user_data)
    if one_user['PASSWORD'] != pw
      @logger.debug "Changing PASSWD of #{one_user['NAME'].inspect} " \
                    "from #{one_user['PASSWORD'].inspect} to #{pw.inspect}"
      rc = one_user.passwd(pw)
      self.class.check_retval(rc, @logger)
    end

    # add groups
    user_set_groups(one_user, user_data.groups)

    # del groups
    one_grps = user_group_names(one_user)
    grps_to_del = one_grps - user_data.groups
    user_del_groups(one_user, grps_to_del) unless grps_to_del.empty?

    # properties
    user_set_properties(one_user, user_data)
  end

  def user_del_groups(user, groups)
    @logger.debug "Deleting groups #{groups.to_s} of #{user['NAME'].inspect}"
    groups.each do |del_group|
      rc = user.delgroup(gname_to_gid(del_group))

      if ::OpenNebula::is_error?(rc)
        unless rc.message.include?('User is not part of this group')
          self.class.check_retval(rc, @logger)
        end
      end
    end
  end

  def user_set_properties(user, user_data)
    file = "#{File.expand_path('..', __FILE__)}/templates/user_properties.erb"
    template = ERB.new(File.new(file).read, nil, '-')

    old_token_password = user['TEMPLATE/TOKEN_PASSWORD'] ? user['TEMPLATE/TOKEN_PASSWORD'] : ""
    old_default_view = user['TEMPLATE/DEFAULT_VIEW'] ? user['TEMPLATE/DEFAULT_VIEW'] : "cloud"
    old_lang = user['TEMPLATE/LANG'] ? user['TEMPLATE/LANG'] : "en_US"
    old_table_order = user['TEMPLATE/TABLE_ORDER'] ? user['TEMPLATE/TABLE_ORDER'] : "desc"
    old_vnc_wss = "yes"

    props = template.result(binding)

    @logger.debug "Updating properties for #{user['NAME'].inspect} with #{props.inspect}"
    rc = user.update(props)
    self.class.check_retval(rc, @logger)
  end

  def remove_user(username)
    if username.include?('oneadmin')
      raise "Cannot remove user #{username.inspect}!"
    end

    user_data = uname_to_data(username)
    user_groups = user_group_names(user_data)
    unless (user_groups & EXCLUDED_ONE_GROUPS).empty?
      raise "Cannot remove user #{username.inspect}! It's a member of #{EXCLUDED_ONE_GROUPS.to_s}."
    end

    kill_vms(user_data['ID'])
    remove_images(user_data['ID'])
    remove_networks(user_data['ID'])

    rc = user_data.delete
    self.class.check_retval(rc, @logger)
  end

  def uname_to_data(username)
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
    uid = uid.to_i
    raise "Cannot remove VMs for a user without an ID > 0! [#{uid.inspect}]" if uid == 0

    rc = @vm_pool.info(uid)
    self.class.check_retval(rc, @logger)

    @vm_pool.each do |vm|
      next unless vm['UID'].to_i == uid
      @logger.debug "Killing VM [#{vm.id.inspect}] of user [#{uid.inspect}]"
      vm.shutdown(hard = true)
    end
  end

  def remove_images(uid)
    # TODO
  end

  def remove_networks(uid)
    # TODO
  end

  class << self

    def user_pool(client, logger)
      user_pool = ::OpenNebula::UserPool.new(client)
      rc = user_pool.info
      check_retval(rc, logger)

      user_pool
    end

    def group_pool(client, logger)
      group_pool = ::OpenNebula::GroupPool.new(client)
      rc = group_pool.info
      check_retval(rc, logger)

      group_pool
    end

    def vm_pool(client, logger)
      vm_pool = ::OpenNebula::VirtualMachinePool.new(client)
      rc = vm_pool.info_all
      check_retval(rc, logger)

      vm_pool
    end

    def check_retval(rc, logger)
      if ::OpenNebula.is_error?(rc)
        logger.error rc.message
        raise rc.message
      end
    end

    def escape_dn(dn)
        dn.gsub(/\s/) { |s| "\\"+s[0].ord.to_s(16) }
    end

    def unescape_dn(dn)
        dn.gsub(/\\[0-9a-f]{2}/) { |s| s[1,2].to_i(16).chr }
    end

  end

end
