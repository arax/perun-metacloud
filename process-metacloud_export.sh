########################################################################################################################
# 'process-metacloud_export.sh' expects data in the following format:
#
# [
#  {
#    "login": "example",
#    "groups": [
#      "metacloud",
#      "intracloud",
#      "fedcloud.egi.eu"
#    ],
#    "krb_principals": [
#      "example@META"
#    ],
#    "cert_dns": [
#      "/C=CZ/O=CESNET/CN=example@meta.cesnet.cz",
#      "/DC=cz/DC=cesnet-ca/O=CESNET/CN=John Doe"
#    ],
#    "ssh_keys": [
#      "ssh-rsa AAAAB3NzaC1...XHKH6UuLhw== example@mycroft"
#    ],
#    "mail": "example@cesnet.cz",
#    "full_name": "John Doe"
#  },
#  ...
# ]
#
########################################################################################################################

SOURCE="${BASH_SOURCE[0]}"

# resolve $SOURCE until the file
# is no longer a symlink
while [ -h "$SOURCE" ]; do
	DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
	SOURCE="$(readlink "$SOURCE")"

	# if $SOURCE was a relative symlink, we need to resolve it
	# relative to the path where the symlink file was located
	[[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

PROTOCOL_VERSION=`/usr/bin/env ruby -I ${DIR}/lib -e 'require "metacloud_export/version"; puts MetacloudExport::VERSION'`

create_lock

function process {
	OUTPUT=`${DIR}/process-metacloud_export.rb --source file://${WORK_DIR}/metacloud_export`
	catch_error ($? $OUTPUT)
}
