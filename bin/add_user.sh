OPENLDAP_USER="$1"
EXAMPLE_GROUP="$2"
IFS=',' read -r -a EXAMPLE_USERS <<< "${OPENLDAP_USER}"

OPENLDAP_BASE_DN='dc=example,dc=com'
OPENLDAP_ROOT_CN='admin'
OPENLDAP_ROOT_DN="cn=${OPENLDAP_ROOT_CN},${OPENLDAP_BASE_DN}"
OPENLDAP_ROOT_PASSWORD='Admin1234!'
OPENLDAP_USERS_BASE_DN="ou=users,$OPENLDAP_BASE_DN"
COMMON_DEFAULT_PASSWORD='Admin1234!'
KERBEROS_REALM='COMPUTE.INTERNAL'

ldapsearch -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD -b "cn=$EXAMPLE_GROUP,ou=groups,$OPENLDAP_BASE_DN"
# --------------------------------------    Migrating Kerberos DB Operations   --------------------------------------- #
addOpenldapUsers() {
    for user in "${EXAMPLE_USERS[@]}"; do
        USER_UID=$((2000+$RANDOM%999))
        ldapsearch -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD -b "cn=$EXAMPLE_GROUP,ou=groups,$OPENLDAP_BASE_DN" >& /dev/null
        if [ "$?" != "0" ]; then
            GROUP_GID=$((3000+$RANDOM%999))
            echo "用户组不存在 --${GROUP_GID}"
        else
            GROUP_GID=`ldapsearch -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD -b "ou=groups,$OPENLDAP_BASE_DN" -s sub "(&(objectClass=posixGroup)(cn=$EXAMPLE_GROUP))" gidNumber | grep "^gidNumber:" | awk '{print $2}'`
            echo "用户组存在 --${GROUP_GID}"
        fi


        # add user
        cat << EOF | ldapadd -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD
dn: uid=$user,$OPENLDAP_USERS_BASE_DN
objectClass: posixAccount
objectClass: top
objectClass: inetOrgPerson
uid: $user
displayName: $user
sn: $user
homeDirectory: /home/$user
cn: $user
uidNumber: $USER_UID
gidNumber: $GROUP_GID
userPassword: $(slappasswd -s $COMMON_DEFAULT_PASSWORD)
EOF

        #检查是否有groups，如果不存在就创建，如果存在就直接把刚刚的用户添加到groups中
        ldapsearch -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD -b "cn=$EXAMPLE_GROUP,ou=groups,$OPENLDAP_BASE_DN" >& /dev/null
        if [ "$?" != "0" ]; then
            echo '不存在，需要创建'
            cat << EOF | ldapadd -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD
dn: cn=$EXAMPLE_GROUP,ou=groups,$OPENLDAP_BASE_DN
cn: $EXAMPLE_GROUP
objectclass: top
objectclass: posixGroup
gidNumber: $GROUP_GID
memberUid: $user
EOF
        else
            echo '已经存在添加用户'
            cat << EOF | ldapmodify -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD
dn: cn=$EXAMPLE_GROUP,ou=groups,$OPENLDAP_BASE_DN
changetype: modify
add: memberUid
memberUid: $user
EOF
        fi
    done
}

addKerberosUsers() {
    # install expect in case not installed
    yum -y install expect
    # if kerberos db is migrated to openldap, -x parameter would be required

   for user in "${EXAMPLE_USERS[@]}"; do
		/usr/bin/expect <<EOF
			spawn kadmin -w "$OPENLDAP_ROOT_PASSWORD" -p kadmin/admin -q "addprinc -x dn=uid=$user,$OPENLDAP_USERS_BASE_DN $user"
			expect {
				"Enter password*" {
					send "$COMMON_DEFAULT_PASSWORD\r"
					expect "Re-enter password*" { send "$COMMON_DEFAULT_PASSWORD\r" }
				}
			}
			expect eof
EOF
	done

}

updateOpenldapUsersPasswordSetting() {
    for user in "${EXAMPLE_USERS[@]}"; do
        cat << EOF | ldapadd -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD
dn: uid=$user,$OPENLDAP_USERS_BASE_DN
changetype: modify
replace: userPassword
userPassword: {SASL}$user@$KERBEROS_REALM
EOF
    done
}

restartRangerSync(){
    ranger-usersync stop
	ranger-usersync start
}

addOpenldapUsers
addKerberosUsers
updateOpenldapUsersPasswordSetting
restartRangerSync
