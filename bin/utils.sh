#!/usr/bin/env bash

printHeading()
{
    title="$1"
    if [ "$TERM" = "dumb" -o "$TERM" = "unknown" ]; then
        paddingWidth=60
    else
        paddingWidth=$((($(tput cols)-${#title})/2-5))
    fi
    printf "\n%${paddingWidth}s"|tr ' ' '='
    printf "    $title    "
    printf "%${paddingWidth}s\n\n"|tr ' ' '='
}

validateTime()
{
    if [ "$1" = "" ]
    then
        echo "Time is missing!"
        exit 1
    fi
    TIME=$1
    date -d "$TIME" >/dev/null 2>&1
    if [ "$?" != "0" ]
    then
        echo "Invalid Time: $TIME"
        exit 1
    fi
}

installXmlstarletIfNotExists() {
    if ! xmlstarlet --version &>/dev/null; then
        yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E '%{rhel}').noarch.rpm &>/dev/null
        yum -y install xmlstarlet &>/dev/null
    fi
}

distributeInstaller() {
    user="$1"
    host="$2"
    installer=ranger-emr-cli-installer
    ssh -o StrictHostKeyChecking=no -i $SSH_KEY -T $user@$host sudo rm -rf /tmp/$installer
    scp -o StrictHostKeyChecking=no -i $SSH_KEY -r $APP_HOME $user@$host:/tmp/$installer &>/dev/null
    ssh -o StrictHostKeyChecking=no -i $SSH_KEY -T $user@$host <<EOSSH
        sudo rm -rf $APP_REMOTE_HOME
        sudo mv /tmp/$installer $APP_REMOTE_HOME
EOSSH
}

# Be careful! do NOT echo anything except $confirmed
# because we use it as return value!!
askForConfirmation() {
    local message="$1"
    local answered="false"
    local confirmed="false"
    while [[ "$answered" != "true" ]]; do
        read -p "$message [y/n]: " answer
        case "$answer" in
            y|Y)
                confirmed="true"; answered="true"
            ;;
            n|N)
                confirmed="false"; answered="true"
            ;;
            *)
                confirmed="false"; answered="false"
            ;;
        esac
    done
    echo $confirmed
}

generateCertificateForTrino(){
	sudo mkdir "$CERTS_PATH"
	sudo chown ec2-user:ec2-user /tmp/certs
	cd "$CERTS_PATH"
	openssl req -x509 -newkey rsa:1024 -keyout privateKey.pem -out certificateChain.pem -days 365 -nodes -subj "/C=US/ST=Washington/L=Seattle/O=MyOrg/OU=MyDept/CN=${CERTIFICATE_CN_REGION}"
	cp certificateChain.pem trustedCertificates.pem
	zip -r -X my-certs.zip certificateChain.pem privateKey.pem trustedCertificates.pem
	
	aws s3 cp my-certs.zip "s3://${S3_BUCKET}/emr_bootstrap_file/certs/"
}