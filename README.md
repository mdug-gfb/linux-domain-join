# linux-domain-join
Shell script to join Linux to AD in AWS environment

This script is modified from the AWS domain join script as part of the SSM Agent
Using SSSD instead of Winbind
The original can be found here

https://github.com/aws/amazon-ssm-agent/blob/mainline/agent/plugins/domainjoin/domainjoin_unix_script.go

Also followed some steps from here to use AWS Secrets Manager to store password for user allowed to do an AD Join

https://docs.aws.amazon.com/directoryservice/latest/admin-guide/seamlessly_join_linux_instance.html

Currently only tested with Amazon Linux 2. Other distros will fail as steps have not been modified from original

Storing SSH public keys in AD

https://blog.laslabs.com/2016/08/storing-ssh-keys-in-active-directory/

Using SSSD to query AD for public keys (first answer)

https://askubuntu.com/questions/906170/ssh-with-ldap-authentication-activedirectory-and-ssh-keys-stored-in-ad

Invoke as follows

\# ./domain-join.sh --directory-id <AWS Directory ID> --directory-name <AD domain name> --directory-ou <Optional OU to use> --efsserver <Optional EFS Server for homedirs> --dockergroup <Optional AD docker group>
