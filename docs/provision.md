First it create the loging color 

Provisio script first check  the os 
then it start  update the package then make a list of packages which is needed to run infra 


after that is installs the necessary librayes and the it  creates the 2  user by checking that is there exits a user 
or not one is ops (sudo) other is just worker 

if dosn't exist create user 
then it start python http server 

then it copy all the necessary file to the new userspace 

and establish firewall


after the reboot it automatically start the services and the  user also exits  with the  service