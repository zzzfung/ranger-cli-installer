#!/bin/bash

EXAMPLE_USERS=("user01" "user02")
OPENLDAP_ROOT_CN="root"
OPENLDAP_BASE_DN="dc=test,dc=com"
OPENLDAP_ROOT_DN="cn=${OPENLDAP_ROOT_CN},${OPENLDAP_BASE_DN}"
OPENLDAP_ROOT_PASSWORD="Gcp@admin2024"
OPENLDAP_USERS_BASE_DN="ou=users,$OPENLDAP_BASE_DN"
COMMON_DEFAULT_PASSWORD="user"

addOpenldapUsers() {
# add user
for user in "${EXAMPLE_USERS[@]}"; do
USER_UID=$((2000+$RANDOM%999))
GROUP_GID=$((3000+$RANDOM%999))

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

if [ "$user" == "user01" ]; then
EXAMPLE_GROUP="bigdata"
cat << EOF | ldapadd -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD
dn: cn=$EXAMPLE_GROUP,ou=groups,$OPENLDAP_BASE_DN
cn: $EXAMPLE_GROUP
objectclass: top
objectclass: posixGroup
gidNumber: $GROUP_GID
memberUid: $user
EOF
else
EXAMPLE_GROUP="risk"
cat << EOF | ldapadd -D "$OPENLDAP_ROOT_DN" -w $OPENLDAP_ROOT_PASSWORD
dn: cn=$EXAMPLE_GROUP,ou=groups,$OPENLDAP_BASE_DN
cn: $EXAMPLE_GROUP
objectclass: top
objectclass: posixGroup
gidNumber: $GROUP_GID
memberUid: $user
EOF
fi

done
}

addOpenldapUsers