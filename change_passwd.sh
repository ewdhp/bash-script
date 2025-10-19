#!/bin/sh

# Generate a strong 16-character password
PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom | head -c 16)

# Use expect to feed password to passwd
expect <<EOF
spawn passwd root
expect "New password:"
send "$PASSWORD\r"
expect "Retype new password:"
send "$PASSWORD\r"
expect eof
EOF

# Save password to file (plain text)
echo "$PASSWORD" > ./root-password.txt
