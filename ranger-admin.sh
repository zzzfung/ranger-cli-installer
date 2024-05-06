#!/bin/sh

# Run the below commands as root
if [ "$(whoami)" != "root" ]; then
    echo "Run me as [ root ] user!"
    exit 1
fi

OPT_KEYS=(
    REGION ARN_ROOT SSH_KEY ACCESS_KEY_ID SECRET_ACCESS_KEY SOLUTION ENABLE_CROSS_REALM_TRUST TRUSTING_REALM TRUSTING_DOMAIN TRUSTING_HOST RANGER_SECRETS_DIR
    AUTH_PROVIDER AD_DOMAIN AD_DOMAIN_ADMIN AD_DOMAIN_ADMIN_PASSWORD AD_URL AD_BASE_DN RANGER_BIND_DN RANGER_BIND_PASSWORD HUE_BIND_DN HUE_BIND_PASSWORD AD_USER_OBJECT_CLASS
    SKIP_INSTALL_OPENLDAP OPENLDAP_URL OPENLDAP_USER_DN_PATTERN OPENLDAP_GROUP_SEARCH_FILTER OPENLDAP_BASE_DN RANGER_BIND_DN RANGER_BIND_PASSWORD HUE_BIND_DN HUE_BIND_PASSWORD OPENLDAP_USER_OBJECT_CLASS
    OPENLDAP_BASE_DN OPENLDAP_ROOT_CN OPENLDAP_ROOT_DN OPENLDAP_ROOT_PASSWORD OPENLDAP_USERS_BASE_DN
    JAVA_HOME SKIP_INSTALL_MYSQL MYSQL_HOST MYSQL_ROOT_PASSWORD MYSQL_RANGER_DB_USER_PASSWORD
    SKIP_INSTALL_SOLR SOLR_HOST RANGER_HOST RANGER_PORT RANGER_REPO_URL RANGER_VERSION RANGER_PLUGINS
    KERBEROS_KDC_HOST SKIP_MIGRATE_KERBEROS_DB OPENLDAP_HOST
    EMR_CLUSTER_ID MASTER_INSTANCE_GROUP_ID SLAVE_INSTANCE_GROUP_IDS EMR_MASTER_NODES EMR_SLAVE_NODES EMR_CLUSTER_NODES EMR_ZK_QUORUM EMR_HDFS_URL EMR_FIRST_MASTER_NODE
    EXAMPLE_GROUP EXAMPLE_USERS SKIP_CONFIGURE_HUE RESTART_INTERVAL CERTS_PATH S3_BUCKET
)

# 初始化服务器
init() {
    installTools
    configSsh
    installJdk8IfNotExists
}

# 安装常用工具
installTools() {
    printHeading "INSTALL COMMON TOOLS"
    yum -y update
    # install common tools
    yum -y install git xmlstarlet lsof lrzsz vim wget zip unzip expect tree htop iotop nc telnet jq
    # change timezone
    # cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    yum install mysql -y
    systemctl enable mysqld
    systemctl start mysqld
}

# ssh 配置
configSsh() {
    printHeading "CONFIG SSH"
    # enable ssh login with password
    sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/g" /etc/ssh/sshd_config
    echo "PermitRootLogin yes" | tee -a  /etc/ssh/sshd_config
    echo "RSAAuthentication yes" | tee -a  /etc/ssh/sshd_config
    systemctl restart sshd
}

# 安装JDK8
installJdk8IfNotExists() {
    printHeading "INSTALL OPEN JDK8"
    # 安装
    yum install -y java-1.8.0-openjdk java-1.8.0-openjdk-devel
    # 获取Java路径 (使用通配符匹配)
    JAVA_HOME=$(find /usr/lib/jvm -name "java-1.8.0-openjdk*" -type d | head -n 1)

    # 追加到/etc/profile
    echo "export JAVA_HOME=$JAVA_HOME" >> /etc/profile
    echo "export PATH=\$PATH:\$JAVA_HOME/bin" >> /etc/profile
    echo "export CLASSPATH=.:\$JAVA_HOME/lib/dt.jar:\$JAVA_HOME/lib/tools.jar" >> /etc/profile
    # 生效
    source /etc/profile
}

# 测试MySql连接
testMySqlConnectivity() {
    printHeading "TEST MYSQL CONNECTIVITY"
    mysql -h$MYSQL_HOST -uroot -p$MYSQL_ROOT_PASSWORD -e "select 1;" &>/dev/null
    if [ "$?" = "0" ]; then
        echo "Connecting to mysql server is SUCCESSFUL!!"
    else
        echo "Connecting to mysql server is FAILED!!"
        exit 1
    fi
}

# 下载Ranger Repo
downloadRangerRepo() {
    if [ ! -d /tmp/ranger-repo ]; then
        printHeading "DOWNLOAD RANGER"
        curl --connect-timeout 5 -I $RANGER_REPO_FILE_URL &>/dev/null
        if [ ! "$?" = "0" ]; then
            echo "Given Ranger Repo URL: $RANGER_REPO_FILE_URL is inaccessible, please check network and security group settings!"
            exit 1
        fi
#        wget --recursive --no-parent --no-directories --no-host-directories $RANGER_REPO_FILE_URL -P /tmp/ranger-repo &>/dev/null
        wget $RANGER_REPO_FILE_URL -O /tmp/ranger-repo.zip
        unzip -o /tmp/ranger-repo.zip -d /tmp/
    fi
}

# 下载MySql JDBC Driver
installMySqlJdbcDriverIfNotExists() {
    if [ ! -f /usr/share/java/mysql-connector-java.jar ]; then
        printHeading "INSTALL MYSQL JDBC DRIVER"
        wget https://downloads.mysql.com/archives/get/p/3/file/mysql-connector-j-8.0.31.tar.gz -P /tmp/
        tar -zxvf /tmp/mysql-connector-j-8.0.31.tar.gz -C /tmp &>/dev/null
        mkdir -p /usr/share/java/
        cp /tmp/mysql-connector-j-8.0.31/mysql-connector-j-8.0.31.jar /usr/share/java/mysql-connector-java.jar
        echo "Mysql JDBC Driver is installed!"
    fi
}

# 下载solr
installSolrIfNotExists() {
    if [ ! -f /etc/init.d/solr ]; then
        printHeading "INSTALL SOLR"
        # download from offical site, but sometimes, it's slow, so disable it.
        # the private ranger repo had provided solr, it's available at /tmp/ranger-repo/solr-8.6.2.tgz
        # wget https://archive.apache.org/dist/lucene/solr/8.6.2/solr-8.6.2.tgz -P /tmp/ranger-repo
        tar -zxvf /tmp/ranger-repo/solr-8.6.2.tgz -C /tmp &>/dev/null
        # install but do NOT star solr
        /tmp/solr-8.6.2/bin/install_solr_service.sh /tmp/ranger-repo/solr-8.6.2.tgz -n

    fi
}

# 初始化solr
initSolrAsRangerAuditStore() {
    printHeading "INIT SOLR AS RANGER AUDIT STORE"
    tar -zxvf /tmp/ranger-repo/ranger-$RANGER_VERSION-solr_for_audit_setup.tar.gz -C /tmp &>/dev/null
    confFile=/tmp/solr_for_audit_setup/install.properties
    # backup confFile
    cp $confFile $confFile.$(date +%s)
    cp $APP_HOME/conf/ranger-audit/solr-template.properties $confFile
    sed -i "s|@JAVA_HOME@|$JAVA_HOME|g" $confFile
    curDir=$(pwd)
    # must run under project root dir.
    cd /tmp/solr_for_audit_setup
    sh setup.sh
    cd $curDir
    # stop first in case it is already started.
    sudo -u solr /opt/solr/ranger_audit_server/scripts/stop_solr.sh || true
    sudo -u solr /opt/solr/ranger_audit_server/scripts/start_solr.sh
    # waiting for staring, this is required!
    sleep $RESTART_INTERVAL
}

# 测试solr连接
testSolrConnectivity() {
    printHeading "TEST SOLR CONNECTIVITY"
    nc -vz $SOLR_HOST 8983
    if [ "$?" = "0" ]; then
        echo "Connecting to solr server is SUCCESSFUL!!"
    else
        echo "Connecting to solr server is FAILED!!"
        exit 1
    fi
}

# 初始化Ranger DB
initRangerAdminDb() {
    printHeading "INIT RANGER DB"
    cp $APP_HOME/sql/init-ranger-db.sql $APP_HOME/sql/.init-ranger-db.sql
    sed -i "s|@DB_HOST@|$MYSQL_HOST|g" $APP_HOME/sql/.init-ranger-db.sql
    sed -i "s|@MYSQL_RANGER_DB_USER_PASSWORD@|$MYSQL_RANGER_DB_USER_PASSWORD|g" $APP_HOME/sql/.init-ranger-db.sql
    mysql -h$MYSQL_HOST -uroot -p$MYSQL_ROOT_PASSWORD -s --prompt=nowarning --connect-expired-password <$APP_HOME/sql/.init-ranger-db.sql
}

configRangerAdminOpenldapProps() {
    confFile="$1"
    sed -i "s|@OPENLDAP_URL@|$OPENLDAP_URL|g" $confFile
    sed -i "s|@OPENLDAP_USER_DN_PATTERN@|$OPENLDAP_USER_DN_PATTERN|g" $confFile
    sed -i "s|@OPENLDAP_GROUP_SEARCH_FILTER@|$OPENLDAP_GROUP_SEARCH_FILTER|g" $confFile
    sed -i "s|@OPENLDAP_BASE_DN@|$OPENLDAP_BASE_DN|g" $confFile
    sed -i "s|@RANGER_BIND_DN@|$RANGER_BIND_DN|g" $confFile
    sed -i "s|@RANGER_BIND_PASSWORD@|$RANGER_BIND_PASSWORD|g" $confFile
    sed -i "s|@OPENLDAP_USER_OBJECT_CLASS@|$OPENLDAP_USER_OBJECT_CLASS|g" $confFile
}

configRangerAdminCommonProps() {
    confFile="$1"
    sed -i "s|@DB_HOST@|$MYSQL_HOST|g" $confFile
    sed -i "s|@DB_ROOT_PASSWORD@|$MYSQL_ROOT_PASSWORD|g" $confFile
    sed -i "s|@SOLR_HOST@|$SOLR_HOST|g" $confFile
    sed -i "s|@DB_PASSWORD@|$MYSQL_RANGER_DB_USER_PASSWORD|g" $confFile
    sed -i "s|@RANGER_VERSION@|$RANGER_VERSION|g" $confFile
}

configRangerAdminHttpProps() {
    confFile="$1"
    sed -i "s|@POLICYMGR_EXTERNAL_URL@|$RANGER_URL|g" $confFile
    sed -i "s|@POLICYMGR_HTTP_ENABLED@|true|g" $confFile
    sed -i "s|@POLICYMGR_HTTPS_KEYSTORE_FILE@||g" $confFile
    sed -i "s|@POLICYMGR_HTTPS_KEYSTORE_KEYALIAS@||g" $confFile
    sed -i "s|@POLICYMGR_HTTPS_KEYSTORE_PASSWORD@||g" $confFile
}

installRangerAdmin() {
    printHeading "INSTALL RANGER ADMIN FOR AD"
    # remove all existing files
    rm -rf /opt/ranger-$RANGER_VERSION-admin
    rm -rf /etc/ranger/admin
    rm -rf /var/log/ranger/admin
    tar -zxvf /tmp/ranger-repo/ranger-$RANGER_VERSION-admin.tar.gz -C /opt/ &>/dev/null
    installHome=/opt/ranger-$RANGER_VERSION-admin

    confFile=$installHome/install.properties
    # backup existing version of install.properties
    cp $confFile $confFile.$(date +%s)
    # copy a new version from template file
    cp -f $APP_HOME/conf/ranger-admin/$AUTH_PROVIDER-template.properties $confFile
    # ad or ldap configs
    # if [ "$AUTH_PROVIDER" = "ad" ]; then
        # configRangerAdminAdProps $confFile
    # elif [ "$AUTH_PROVIDER" = "openldap" ]; then
    configRangerAdminOpenldapProps $confFile
    # else
    #     echo "Invalid authentication type, only AD and LDAP are supported!"
    #     exit 1
    # fi
    # common configs
    configRangerAdminCommonProps $confFile
    # https or http configs
    # if [ "$SOLUTION" = "emr-native" ]; then
    #     # it's NOT required to add ranger into kerberos
    #     # configRangerAdminKrbProps $confFile
    #     configRangerAdminHttpsProps $confFile
    # elif [ "$SOLUTION" = "open-source" ]; then
    configRangerAdminHttpProps $confFile
    # else
    #     echo "Invalid --solution option value, only true or false are allowed!"
    #     exit 1
    # fi

    curDir=$(pwd)
    # must run under project root dir.
    cd $installHome
    export JAVA_HOME=$JAVA_HOME
    sh setup.sh
    sh set_globals.sh
    cd $curDir
#    installXmlstarletIfNotExists
    # Ranger installation scripts have BUG!!
    # although, for the sake of security, ranger write password to a key store file,
    # however, it does not work, and at the same time, it removes password in xml conf file with "_",
    # so, it can't login after installation! here, write password back to conf xml file!!
#    adminConfFile=/etc/ranger/admin/conf/ranger-admin-site.xml
#    cp $adminConfFile $adminConfFile.$(date +%s)
    # xmlstarlet edit -L -u "/configuration/property/name[.='ranger.jpa.jdbc.password']/../value" -v "$MYSQL_RANGER_DB_USER_PASSWORD" $adminConfFile
    # ranger.service.https.attrib.keystore.pass 这个也得改
    # 上面这个BUG有可能和cred_keystore_filename=$app_home/WEB-INF/classes/conf/.jceks/rangeradmin.jceks这个配置有管！$app_home得改！
    ranger-admin stop || true
    sleep $RESTART_INTERVAL
    ranger-admin start
    # waiting for staring, this is required!
    sleep $RESTART_INTERVAL
}

# 测试Ranger
testRangerAdminConnectivity() {
    printHeading "TEST RANGER CONNECTIVITY"
    nc -vz $RANGER_HOST $RANGER_PORT
    if [ "$?" = "0" ]; then
        echo "Connecting to ranger server is SUCCESSFUL!!"
    else
        echo "Connecting to ranger server is FAILED!!"
        exit 1
    fi
}

configRangerUsersyncOpenldapProps() {
    confFile="$1"
    sed -i "s|@OPENLDAP_URL@|$OPENLDAP_URL|g" $confFile
    sed -i "s|@OPENLDAP_BASE_DN@|$OPENLDAP_BASE_DN|g" $confFile
    sed -i "s|@RANGER_BIND_DN@|$RANGER_BIND_DN|g" $confFile
    sed -i "s|@RANGER_BIND_PASSWORD@|$RANGER_BIND_PASSWORD|g" $confFile
    sed -i "s|@OPENLDAP_USER_OBJECT_CLASS@|$OPENLDAP_USER_OBJECT_CLASS|g" $confFile
}

configRangerUsersyncCommonProps() {
    confFile="$1"
    sed -i "s|@RANGER_VERSION@|$RANGER_VERSION|g" $confFile
    sed -i "s|@RANGER_URL@|$RANGER_URL|g" $confFile
}

# Ranger Usersync用户同步
installRangerUsersync() {
    printHeading "INSTALL RANGER USERSYNC"
    tar -zxvf /tmp/ranger-repo/ranger-$RANGER_VERSION-usersync.tar.gz -C /opt/ &>/dev/null
    installHome=/opt/ranger-$RANGER_VERSION-usersync
    confFile=$installHome/install.properties
    # backup existing version of install.properties
    cp $confFile $confFile.$(date +%s)
    # copy a new version from template file
    cp -f $APP_HOME/conf/ranger-usersync/$AUTH_PROVIDER-template.properties $confFile
    # ad or ldap configs
    if [ "$AUTH_PROVIDER" = "ad" ]; then
        configRangerUsersyncAdProps $confFile
    elif [ "$AUTH_PROVIDER" = "openldap" ]; then
        configRangerUsersyncOpenldapProps $confFile
    else
        echo "Invalid authentication type, only AD and LDAP are supported!"
        exit 1
    fi
    configRangerUsersyncCommonProps $confFile
    # https or http configs
#    if [ "$SOLUTION" = "emr-native" ]; then
#        configRangerUsersyncHttpsProps $confFile
#    elif [ "$SOLUTION" = "open-source" ]; then
#        configRangerUsersyncHttpProps $confFile
#    else
#        echo "Invalid --solution option value, only true or false are allowed!"
#        exit 1
#    fi
    curDir=$(pwd)
    # must run under project root dir.
    cd $installHome
    export JAVA_HOME=$JAVA_HOME
    sh setup.sh
    sh set_globals.sh
    cd $curDir
    # IMPORTANT! must enable usersync in ranger-ugsync-site.xml, by default, it is disabled!
    ugsyncConfFile=/etc/ranger/usersync/conf/ranger-ugsync-site.xml
    cp $ugsyncConfFile $ugsyncConfFile.$(date +%s)

    xmlstarlet ed -L -u "/configuration/property[name='ranger.usersync.enabled']/value" -v "true" $ugsyncConfFile
    ranger-usersync start
}

# 安装Ranger
installRanger() {
    printHeading "INSTALL RANGER"
    testLdapConnectivity
    downloadRangerRepo
    # if [ "$SKIP_INSTALL_MYSQL" = "false" ]; then
    #     installMySqlIfNotExists
    # fi
    testMySqlConnectivity
    installMySqlJdbcDriverIfNotExists
    # installJdk8IfNotExists
    # If skip installing solr, please perform initSolrAsRangerAuditStore
    # operation on remote solr server mannually! this is required!
    if [ "$SKIP_INSTALL_SOLR" = "false" ]; then
        installSolrIfNotExists
        initSolrAsRangerAuditStore
    fi
    testSolrConnectivity
    initRangerAdminDb
    installRangerAdmin
    testRangerAdminConnectivity
    installRangerUsersync
    printHeading "RANGER HAS STARTED!"
}

# 测试
testALL() {
    printHeading "TEST"
}

resetAllOpts() {
    # 删除所有环境变量配置
    # for key in "${OPT_KEYS[@]}"; do
    #     eval unset $key
    # done
    # 如果命令行中没有设置，则为某些配置设置默认值。
    # INIT_EC2_FLAG_FILE='/tmp/init-ec2.flag'
    # MIGRATE_KERBEROS_DB_FLAG='/tmp/migrate-kerberos-db.flag'
    # JAVA_HOME='/usr/lib/jvm/java'
    APP_HOME=$(pwd)
    COMMON_DEFAULT_PASSWORD='Admin1234!'
    RANGER_VERSION='2.2.0'
    RANGER_REPO_URL="https://github.com/bluishglc/ranger-repo/releases/download"
    RANGER_REPO_FILE_URL="https://github.com/bluishglc/ranger-repo/releases/download/2.2.0/ranger-repo.zip"
    RANGER_SECRETS_DIR="/opt/ranger-$RANGER_VERSION-secrets"
    # AUDIT_EVENTS_LOG_GROUP="/aws-emr/audit-events"
    RANGER_HOST=$(hostname -f)
    # KERBEROS_KADMIN_PASSWORD=$COMMON_DEFAULT_PASSWORD
    OLKB_EXAMPLE_USER_PASSWORD=$COMMON_DEFAULT_PASSWORD
    MYSQL_HOST=$RANGER_HOST
    MYSQL_ROOT_PASSWORD=$COMMON_DEFAULT_PASSWORD
    MYSQL_RANGER_DB_USER_PASSWORD=$COMMON_DEFAULT_PASSWORD
    SOLR_HOST=$RANGER_HOST
    RESTART_INTERVAL=30
    # SKIP_INSTALL_MYSQL=false
    SKIP_INSTALL_SOLR=false
    SKIP_INSTALL_OPENLDAP=false
    SKIP_CONFIGURE_HUE=false
    SKIP_MIGRATE_KERBEROS_DB=false
    OPENLDAP_BASE_DN='dc=example,dc=com'
    OPENLDAP_ROOT_CN='admin'
    OPENLDAP_ROOT_PASSWORD=$COMMON_DEFAULT_PASSWORD
    EXAMPLE_GROUP="example-group"
    CERTS_PATH="/tmp/certs"
}

parseArgs() {
    # reset all config items first.
    resetAllOpts

    optString="\
        region:,ssh-key:,access-key-id:,secret-access-key:,java-home:,\
        skip-migrate-kerberos-db:,kerberos-realm:,kerberos-kdc-host:,kerberos-kadmin-password:,\
        solution:,enable-cross-realm-trust:,trusting-realm:,trusting-domain:,trusting-host:,ranger-version:,ranger-repo-url:,restart-interval:,ranger-host:,ranger-secrets-dir:,ranger-plugins:,\
        auth-provider:,ad-host:,ad-domain:,ad-domain-admin:,ad-domain-admin-password:,ad-base-dn:,ad-user-object-class:,\
        openldap-host:,openldap-base-dn:,openldap-root-cn:,openldap-root-password:,example-users:,\
        sssd-bind-dn:,sssd-bind-password:,\
        skip-install-openldap:,openldap-user-dn-pattern:,openldap-group-search-filter:,openldap-base-dn:,ranger-bind-dn:,ranger-bind-password:,hue-bind-dn:,hue-bind-password:,openldap-user-object-class:,\
        skip-install-mysql:,mysql-host:,mysql-root-password:,mysql-ranger-db-user-password:,skip-install-solr:,solr-host:,\
        emr-cluster-id:,skip-configure-hue:,s3-bucket:\
    "
    # IMPORTANT!! -o option can not be omitted, even there are no any short options!
    # otherwise, parsing will go wrong!
    OPTS=$(getopt -o "" -l "$optString" -- "$@")
    exitCode=$?
    if [ $exitCode -ne 0 ]; then
        echo "".
#        printUsage
        exit 1
    fi
    eval set -- "$OPTS"
    while true; do
        case "$1" in
            --region)
                REGION="${2}"

                # 1. ec2.internal for us-east-1
                # 2. compute.internal for other regions
                if [ "$REGION" = "us-east-1" ]; then
                    CERTIFICATE_CN="*.ec2.internal"
                    CERTIFICATE_CN_REGION="*.${REGION}.ec2.internal"
                else
                    # BE CAREFUL:
                    # SSL: certificate subject name '*.compute.internal' does not match target host name 'ip-x-x-x-x.cn-north-1.compute.internal'
                    # I don't know why emr native plugin can work with cn "*.compute.internal", it seems emr native does NOT sync policies via https.
                    # BUT for opensource plugins, "*.compute.internal"??? testing!!!
                    # CERTIFICATE_CN="*.${REGION}.compute.internal"
                    CERTIFICATE_CN="*.compute.internal"
                    CERTIFICATE_CN_REGION="*.${REGION}.compute.internal"
                fi
                # 1. for china, arn root is aws-cn
                # 2. for others, arn root is aws
                if [ "$REGION" = "cn-north-1" -o "$REGION" = "cn-northwest-1" ]; then
                    ARN_ROOT="aws-cn"
                    SERVICE_POSTFIX="com.cn"
                else
                    ARN_ROOT="aws"
                    SERVICE_POSTFIX="com"
                fi
                shift 2
                ;;
            --access-key-id)
                ACCESS_KEY_ID="${2}"
                shift 2
                ;;
            --secret-access-key)
                SECRET_ACCESS_KEY="${2}"
                shift 2
                ;;
            --solution)
                SOLUTION="${2}"
                if [ "$SOLUTION" = "open-source" ]; then
                    RANGER_PROTOCOL="http"
                    RANGER_PORT="6080"
                # for emr-native solution, https is required!
                elif [ "$SOLUTION" = "emr-native" ]; then
                    RANGER_PROTOCOL="https"
                    RANGER_PORT="6182"
                else
                    echo "For --solution option, only 'open-source' or 'emr-native' is acceptable!"
                    exit 1
                fi
                shift 2
                ;;
            --auth-provider)
                AUTH_PROVIDER="${2,,}"
                shift 2
                ;;
            --skip-migrate-kerberos-db)
                if [ "$2" != "true" -a "$2" != "false" ]; then
                    echo "For --skip-migrate-kerberos-db option, only 'true' or 'false' is acceptable!"
                    exit 1
                fi
                SKIP_MIGRATE_KERBEROS_DB="$2"
                shift 2
                ;;
            --kerberos-realm)
                KERBEROS_REALM="${2}"
                shift 2
                ;;
            --kerberos-kdc-host)
                KERBEROS_KDC_HOST="${2}"
                shift 2
                ;;
            --kerberos-kadmin-password)
                KERBEROS_KADMIN_PASSWORD="${2}"
                shift 2
                ;;
            --enable-cross-realm-trust)
                if [ "$2" != "true" -a "$2" != "false" ]; then
                    echo "For --enable-cross-realm-trust option, only 'true' or 'false' is acceptable!"
                    exit 1
                fi
                ENABLE_CROSS_REALM_TRUST="$2"
                shift 2
                ;;
            --trusting-realm)
                TRUSTING_REALM="${2}"
                shift 2
                ;;
            --trusting-domain)
                TRUSTING_DOMAIN="${2}"
                shift 2
                ;;
            --trusting-host)
                TRUSTING_HOST="${2}"
                shift 2
                ;;
            --ad-host)
                AD_HOST="$2"
                AD_URL="ldap://$AD_HOST"
                shift 2
                ;;
            --ad-domain)
                AD_DOMAIN="$2"
                shift 2
                ;;
            --ad-domain-admin)
                AD_DOMAIN_ADMIN="$2"
                shift 2
                ;;
            --ad-domain-admin-password)
                AD_DOMAIN_ADMIN_PASSWORD="$2"
                shift 2
                ;;
            --ad-base-dn)
                AD_BASE_DN="$2"
                shift 2
                ;;
            --ad-user-object-class)
                AD_USER_OBJECT_CLASS="$2"
                shift 2
                ;;
            --openldap-user-dn-pattern)
                OPENLDAP_USER_DN_PATTERN="$2"
                shift 2
                ;;
            --openldap-group-search-filter)
                OPENLDAP_GROUP_SEARCH_FILTER="$2"
                shift 2
                ;;
            --openldap-base-dn)
                OPENLDAP_BASE_DN="$2"
                shift 2
                ;;
            --ranger-bind-dn)
                RANGER_BIND_DN="$2"
                shift 2
                ;;
            --ranger-bind-password)
                RANGER_BIND_PASSWORD="$2"
                shift 2
                ;;
            --hue-bind-dn)
                HUE_BIND_DN="$2"
                shift 2
                ;;
            --hue-bind-password)
                HUE_BIND_PASSWORD="$2"
                shift 2
                ;;
            --openldap-user-object-class)
                OPENLDAP_USER_OBJECT_CLASS="$2"
                shift 2
                ;;
            --java-home)
                JAVA_HOME="$2"
                shift 2
                ;;
            --skip-install-mysql)
                if [ "$2" != "true" -a "$2" != "false" ]; then
                    echo "For --skip-install-mysql option, only 'true' or 'false' is acceptable!"
                    exit 1
                fi
                SKIP_INSTALL_MYSQL="$2"
                shift 2
                ;;
            --ranger-host)
                RANGER_HOST="$2"
                shift 2
                ;;
            --mysql-host)
                MYSQL_HOST="$2"
                shift 2
                ;;
            --mysql-root-password)
                MYSQL_ROOT_PASSWORD="$2"
                shift 2
                ;;
            --mysql-ranger-db-user-password)
                MYSQL_RANGER_DB_USER_PASSWORD="$2"
                shift 2
                ;;
            --skip-install-solr)
                if [ "$2" != "true" -a "$2" != "false" ]; then
                    echo "For --skip-install-solr option, only 'true' or 'false' is acceptable!"
                    exit 1
                fi
                SKIP_INSTALL_SOLR="$2"
                shift 2
                ;;
            --solr-host)
                SOLR_HOST="$2"
                shift 2
                ;;
            --ranger-version)
                RANGER_VERSION="$2"
                shift 2
                ;;
            --ranger-repo-url)
                RANGER_REPO_URL="$2"
                shift 2
                ;;
            --ranger-secrets-dir)
                RANGER_SECRETS_DIR="$2"
                shift 2
                ;;
            --ranger-plugins)
                IFS=', ' read -r -a RANGER_PLUGINS <<< "${2,,}"
                shift 2
                ;;
            --emr-cluster-id)
                # resolving emr cluster information MUST put off to init-ec2 done
                # because resolving emr cluster nodes vars need jq & aws cli
                EMR_CLUSTER_ID="$2"
                # it is REQUIRED to postpone the initialization of following vars!
#                EMR_MASTER_NODES=($(getEmrMasterNodes))
#                EMR_SLAVE_NODES=($(getEmrSlaveNodes))
#                EMR_CLUSTER_NODES=("${EMR_MASTER_NODES[@]}" "${EMR_SLAVE_NODES[@]}")

#                # EMR_ZK_QUORUM looks like 'node1,node2,node3'
#                EMR_ZK_QUORUM=$(IFS=,; echo "${EMR_MASTER_NODES[*]}")
#                # add hdfs:// prefix and :8020 postfix, EMR_HDFS_URL looks like 'hdfs://node1:8020,hdfs://node2:8020,hdfs://node3:8020'
#                EMR_HDFS_URL=$(echo $EMR_ZK_QUORUM | sed -E 's/([^,]+)/hdfs:\/\/\1:8020/g')
#                # NOTE: ranger hive plugin will use hiveserver2 address, for single master node EMR cluster,
#                # it is master node, for multi masters EMR cluster, all 3 master nodes will install hiverserver2
#                # usually, there should be a virtual IP play hiverserver2 role, but EMR has no such config.
#                # here, we pick first master node as hiveserver2
#                EMR_FIRST_MASTER_NODE=${EMR_MASTER_NODES[0]}

                shift 2
                ;;
            --ssh-key)
                SSH_KEY="$2"
                # chmod in case its mod is not 600
                chmod 600 $SSH_KEY
                shift 2
                ;;
            --skip-install-openldap)
                if [ "$2" != "true" -a "$2" != "false" ]; then
                    echo "For --skip-install-openldap option, only 'true' or 'false' is acceptable!"
                    exit 1
                fi
                SKIP_INSTALL_OPENLDAP="$2"
                shift 2
                ;;
            --openldap-host)
                OPENLDAP_HOST="$2"
                OPENLDAP_URL="ldap://$OPENLDAP_HOST"
                shift 2
                ;;
            --openldap-base-dn)
                OPENLDAP_BASE_DN="$2"
                shift 2
                ;;
            --openldap-root-cn)
                OPENLDAP_ROOT_CN="$2"
                shift 2
                ;;
            --openldap-root-password)
                OPENLDAP_ROOT_PASSWORD="$2"
                shift 2
                ;;
             --sssd-bind-dn)
                SSSD_BIND_DN="$2"
                shift 2
                ;;
            --sssd-bind-password)
                SSSD_BIND_PASSWORD="$2"
                shift 2
                ;;
            --skip-configure-hue)
                if [ "$2" != "true" -a "$2" != "false" ]; then
                    echo "For --skip-configure-hue option, only 'true' or 'false' is acceptable!"
                    exit 1
                fi
                SKIP_CONFIGURE_HUE="$2"
                shift 2
                ;;
            --example-users)
                IFS=', ' read -r -a EXAMPLE_USERS <<< "${2,,}"
                shift 2
                ;;
            --restart-interval)
                RESTART_INTERVAL="$2"
                shift 2
                ;;
            --s3-bucket)
                S3_BUCKET="$2"
                shift 2
                ;;
            --) # No more arguments
                shift
                break
                ;;
            *)
                echo ""
                echo "Invalid option $1." >&2
                printUsage
                exit 1
                ;;
        esac
    done
    shift $((OPTIND-1))
    additionalOpts=$*
    # # build ranger repo file url
    # RANGER_REPO_FILE_URL="$RANGER_REPO_URL/$RANGER_VERSION/ranger-repo.zip"
    # build ranger admin url
    RANGER_URL="${RANGER_PROTOCOL}://${RANGER_HOST}:${RANGER_PORT}"

    # OpenLDAP-Specific vars bassed on base dn
    OPENLDAP_ROOT_DN="cn=${OPENLDAP_ROOT_CN},${OPENLDAP_BASE_DN}"
    OPENLDAP_USERS_BASE_DN="ou=users,$OPENLDAP_BASE_DN"
    ORG_NAME=$(echo $OPENLDAP_BASE_DN | sed 's/dc=//g' | sed 's/,/./g')
    ORG_DC=${ORG_NAME%%.*}

    if [ "$AUTH_PROVIDER" = "ad" ]; then
        # check if all required config items are set
        adKeys=(AD_DOMAIN AD_URL AD_BASE_DN RANGER_BIND_DN RANGER_BIND_PASSWORD)
#        for key in "${adKeys[@]}"; do
#            if [ "$(eval echo \$$key)" = "" ]; then
#                echo "ERROR: [ $key ] is NOT set, it is required for Windows AD config."
#                exit 1
#            fi
#        done
        if [ "$AD_USER_OBJECT_CLASS" = "" ]; then
            # set default value if not set
            AD_USER_OBJECT_CLASS="person"
        fi
    elif [ "$AUTH_PROVIDER" = "openldap" ]; then
#        ldapKeys=(LDAP_URL LDAP_BASE_DN LDAP_RANGER_BIND_DN LDAP_RANGER_BIND_PASSWORD)
#        for key in "${ldapKeys[@]}"; do
#            if [ "$(eval echo \$$key)" = "" ]; then
#                echo "ERROR: [ $key ] is NOT set, it is required for OpenLDAP config."
#                exit 1
#            fi
#        done

        # If not set, assign default value
        if [ "$OPENLDAP_USER_DN_PATTERN" = "" ]; then
            OPENLDAP_USER_DN_PATTERN="uid={0},$OPENLDAP_BASE_DN"
        fi
        if [ "$OPENLDAP_GROUP_SEARCH_FILTER" = "" ]; then
            OPENLDAP_GROUP_SEARCH_FILTER="(member=uid={0},$OPENLDAP_BASE_DN)"
        fi
        if [ "$OPENLDAP_USER_OBJECT_CLASS" = "" ]; then
            OPENLDAP_USER_OBJECT_CLASS="inetOrgPerson"
        fi
    fi

    if [ "$RANGER_BIND_DN" = "" ]; then
        RANGER_BIND_DN="cn=ranger,ou=services,$OPENLDAP_BASE_DN"
    fi
    if [ "$RANGER_BIND_PASSWORD" = "" ]; then
        RANGER_BIND_PASSWORD="$COMMON_DEFAULT_PASSWORD"
    fi
    if [ "$HUE_BIND_DN" = "" ]; then
        HUE_BIND_DN="cn=hue,ou=services,$OPENLDAP_BASE_DN"
    fi
    if [ "$HUE_BIND_PASSWORD" = "" ]; then
        HUE_BIND_PASSWORD="$COMMON_DEFAULT_PASSWORD"
    fi
    if [ "$SSSD_BIND_DN" = "" ]; then
        SSSD_BIND_DN="cn=sssd,ou=services,$OPENLDAP_BASE_DN"
    fi
    if [ "$SSSD_BIND_PASSWORD" = "" ]; then
        SSSD_BIND_PASSWORD="$COMMON_DEFAULT_PASSWORD"
    fi
    # print all resolved options
    printAllOpts
}

printAllOpts() {
    printHeading "CONFIGURATION ITEMS"
    for key in "${OPT_KEYS[@]}"; do
        case $key in
        EMR_CLUSTER_NODES|EMR_MASTER_NODES|EMR_SLAVE_NODES|RANGER_PLUGINS)
            val=$(eval echo \${${key}[@]})
            echo "$key = $val"
            ;;
        *)
            val=$(eval echo \$$key)
            echo "$key = $val"
            ;;
        esac
    done
}

# ============================================参数解析=============================================
# 第一个参数的操作
ACTION="$1"

# 遍历剩余参数
shift
parseArgs "$@"

case $ACTION in
    test)
        test
    ;;
    init)
        init
    ;;
    force-init-ec2)
        forceInitEc2
    ;;
    install)
        install
    ;;
    wait)
        waitForCreatingEmrCluster
    ;;
    # --- Ranger Operations --- #

    install-ranger)
        installRanger
    ;;
    install-ranger-plugins)
        installRangerPlugins
    ;;
    remove)
        remove
    ;;
    create-iam-roles)
        createIamRoles
    ;;
    remove-iam-roles)
        removeIamRoles
    ;;
    create-ranger-secrets)
        createRangerSecrets
    ;;
    create-emr-security-configuration)
        createEmrSecurityConfiguration
    ;;
    test-emr-ssh-connectivity)
        testEmrSshConnectivity
    ;;
    test-emr-namenode-connectivity)
        testEmrNamenodeConnectivity
    ;;
    test-ldap-connectivity)
        testLdapConnectivity
    ;;
    install-mysql)
        installMySqlIfNotExists
    ;;
    test-mysql-connectivity)
        testMySqlConnectivity
    ;;
    install-mysql-jdbc-driver)
        installMySqlJdbcDriverIfNotExists
    ;;
    install-jdk)
        installJdk8IfNotExists
    ;;
    download-ranger-repo)
        downloadRangerRepo
    ;;
    install-solr)
        installSolrIfNotExists
    ;;
    test-solr-connectivity)
        testSolrConnectivity
    ;;
    init-solr-as-ranger-audit-store)
        initSolrAsRangerAuditStore
    ;;
    init-ranger-admin-db)
        initRangerAdminDb
    ;;
    install-ranger-admin)
        initRangerAdminDb
        installRangerAdmin
    ;;
    install-ranger-usersync)
        installRangerUsersync
    ;;
    configure-hue)
        configHue
    ;;

    # --- EMR Operations --- #

    get-emr-latest-cluster-id)
        getEmrLatestClusterId
    ;;
    print-emr-cluster-nodes)
        printEmrClusterNodes
    ;;
    find-emr-log-errors)
        findLogErrors
    ;;

    # --- OpenLDAP Operations --- #

    install-openldap)
        installOpenldap
    ;;

    install-openldap-on-local)
        installOpenldapOnLocal
    ;;

    # --- Kerberos Operations --- #

    # be careful, migrating kerberos db is ONE-TIME operation,
    # it can NOT run twice!
    migrate-kerberos-db)
        migrateKerberosDb
    ;;

    migrate-kerberos-db-on-kdc-local)
        migrateKerberosDbOnKdcLocal
    ;;

    # -- SASL/GSSAPI Operations -- #

    enable-sasl-gssapi)
        enableSaslGssapi
    ;;

    enable-sasl-gssapi-on-openldap-local)
        enableSaslGssapiOnOpenldapLocal
    ;;

    # ----- SSSD Operations ----- #

    install-sssd)
        installSssd
    ;;

    # ----- Example Users Operations ----- #

    add-example-users)
        addExampleUsers
    ;;
    add-example-users-on-kdc-local)
        addExampleUsersOnKdcLocal
    ;;
    add-example-users-on-openldap-local)
        addExampleUsersOnOpenldapLocal
    ;;
    help)
#        printUsage
    ;;
    *)
#        printUsage
    ;;
esac