#!/bin/bash
set -x
#管理员用户
OPENLDAP_ROOT_CN="root"
#g管理员用户密码
OPENLDAP_ROOT_PASSWORD="Gcp@admin2024"
OPENLDAP_BASE_DN="dc=test,dc=com"
OPENLDAP_ROOT_DN="cn=${OPENLDAP_ROOT_CN},${OPENLDAP_BASE_DN}"
#example:OPENLDAP_BASE_DN="dc=test,dc=com" ==>> test.com
ORG_NAME=$(echo $OPENLDAP_BASE_DN | sed 's/dc=//g' | sed 's/,/./g')
#example test.com ==>> test
ORG_DC=${ORG_NAME%%.*}
SSSD_BIND_DN="cn=sssd,ou=services,dc=test,dc=com"
SSSD_BIND_PASSWORD="sssd"
RANGER_BIND_DN="cn=ranger,ou=services,dc=test,dc=com"
RANGER_BIND_PASSWORD="ranger"


installOpenldapOnLocal() {
    installOpenldapPackages
    enableOpenldap
    startOpenldap
    initOpenldap
    enableMemberOf
    disableAnonymousAccess
    createOu
    createServiceAccounts
    testconfigfile
    restartOpenldap

}

installOpenldapPackages(){
    yum -y install openldap openldap-clients openldap-servers compat-openldap openldap-devel migrationtools
}

enableOpenldap(){
    systemctl enable slapd
}

startOpenldap(){
    systemctl start slapd
}

restartOpenldap(){
    systemctl restart slapd
    systemctl status slapd
}

initOpenldap() {

cat << EOF | ldapadd -Y EXTERNAL -H ldapi:///
dn: olcDatabase={1}monitor,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by dn.base="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" read by dn.base="$OPENLDAP_ROOT_DN" read by * none

dn: olcDatabase={2}hdb,cn=config
changetype: modify
add: olcRootPW
olcRootPW: $(slappasswd -s $OPENLDAP_ROOT_PASSWORD)
-
replace: olcRootDN
olcRootDN: $OPENLDAP_ROOT_DN
-
replace: olcSuffix
olcSuffix: $OPENLDAP_BASE_DN
-
add: olcAccess
olcAccess: {0}to attrs=userPassword by self write by dn.base="$OPENLDAP_ROOT_DN" write by anonymous auth by * none
olcAccess: {1}to * by dn.base="$OPENLDAP_ROOT_DN" write by self write by * read
EOF

# import regular schemas
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/cosine.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/core.ldif 
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/collective.ldif 
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/corba.ldif 
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/duaconf.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/dyngroup.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/inetorgperson.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/java.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/misc.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/nis.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/openldap.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/pmi.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/ppolicy.ldif

}

enableMemberOf() {

cat << EOF | ldapadd -Y EXTERNAL -H ldapi:///
dn: cn=module,cn=config
cn: module
objectClass: olcModuleList
olcModuleLoad: memberof
olcModulePath: /usr/lib64/openldap

dn: olcOverlay={0}memberof,olcDatabase={2}hdb,cn=config
objectClass: olcConfig
objectClass: olcMemberOf
objectClass: olcOverlayConfig
objectClass: top
olcOverlay: memberof
olcMemberOfDangling: ignore
olcMemberOfRefInt: TRUE
olcMemberOfGroupOC: groupOfNames
olcMemberOfMemberAD: member
olcMemberOfMemberOfAD: memberOf
EOF

cat << EOF | ldapmodify -Y EXTERNAL -H ldapi:///
dn: cn=module{0},cn=config
add: olcmoduleload
olcmoduleload: refint
EOF

cat << EOF | ldapadd -Y EXTERNAL -H ldapi:///
dn: olcOverlay={1}refint,olcDatabase={2}hdb,cn=config
objectClass: olcConfig
objectClass: olcOverlayConfig
objectClass: olcRefintConfig
objectClass: top
olcOverlay: {1}refint
olcRefintAttribute: memberof member manager owner
EOF
}

disableAnonymousAccess() {
cat << EOF | ldapmodify -Y EXTERNAL -H ldapi:///
dn: cn=config
changetype: modify
add: olcDisallows
olcDisallows: bind_anon

dn: cn=config
changetype: modify
add: olcRequires
olcRequires: authc

dn: olcDatabase={-1}frontend,cn=config
changetype: modify
add: olcRequires
olcRequires: authc
EOF
}

createOu() {
cat << EOF | ldapadd -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD

dn: $OPENLDAP_BASE_DN
objectClass: dcObject
objectClass: organization
dc: $ORG_DC
o: $ORG_DC

dn: ou=users,$OPENLDAP_BASE_DN
objectclass: top
objectclass: organizationalUnit
ou: users
description: OU for user accounts

dn: ou=groups,$OPENLDAP_BASE_DN
objectclass: top
objectclass: organizationalUnit
ou: groups
description: OU for user groups

dn: ou=services,$OPENLDAP_BASE_DN
objectclass: top
objectclass: organizationalUnit
ou: services
description: OU for service accounts
EOF
}

createServiceAccounts() {
# sssd bind user
cat << EOF | ldapadd -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD
dn: $SSSD_BIND_DN
sn: sssd
cn: sssd
objectClass: top
objectclass: person
userPassword: $(slappasswd -s $SSSD_BIND_PASSWORD)
EOF

# ranger bind user
cat << EOF | ldapadd -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD
dn: $RANGER_BIND_DN
sn: ranger
cn: ranger
objectClass: top
objectclass: person
userPassword: $(slappasswd -s $RANGER_BIND_PASSWORD)
EOF
}

#测试配置文件正确性
testconfigfile(){
    slaptest -u
}

installOpenldapOnLocal