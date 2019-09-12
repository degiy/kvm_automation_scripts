#!/usr/bin/perl

# num = platform Pnum
$num=3;

# this script generate several files :
#
# - interfaces_mach_x : lines to add to /etc/network/interfaces to make bridges interfaces on vlan to give host and vms vlans (works for a debian/stretch kvm host). One file for each "x" host (need to use the same intf config : ex : eno2 for back to back comm)
# - hosts : /etc/hosts completion with names for kvm host on different vlans (ex : server_a_vlan_x)
# - vm_hosts : /etc/hosts completion with names for kvm vms on different vlans
# - vm_z.ks : ks to create vm "z"
# - virt-installs : script to launch all the virt-install cmds
# - post_z.sh : script to be invoqued after normal installation of vm "z" that will add missing network interfaces (need ssh on vm "z" to work)
# - virt-kill : script to kill and remove files for all vms
# - virt-start : script to launch all vms
# - virt-stop : script to stop all vms (these 5 latest files are tagged with the host name on comment at the end of each line, use a grep to select the eligibles lines you wanna run, ex : grep 'on e1' virt-start | sh)
#
# this script and the template are supposed to be in the direct parent directory from the one where the script is run. Ex : ../gen.pl (inside a ../run directory for instance)

#--------------------------------------------------------------------------------
# background : 2 hosts hosts vms using kvm
# on hosts : /kvm/vms store the images
#            /kvm/iso store the iso from dist to deploy (centos 7.6 here)
# -rw-r--r-- 1 root root 4588568576 Dec 26 09:32 /kvm/iso/centos_76.iso
# -rw-r--r-- 1 root root 3626434560 Nov 10 12:21 /kvm/iso/debian-9.6.0-amd64-DVD-1.iso
# -rw-r--r-- 1 root root 2903506944 Dec 26 09:22 /kvm/iso/fedora_server_28.iso
#
#            /mnt/iso store the mount of the iso
# /kvm/iso/fedora_server_28.iso on /mnt/iso/f28 type iso9660 (ro,relatime)
# /kvm/iso/centos_76.iso on /mnt/iso/c76 type iso9660 (ro,relatime)
# /kvm/iso/debian-9.6.0-amd64-DVD-1.iso on /mnt/iso/d96 type iso9660 (ro,relatime)
#
#            nfs server is running to export /mnt/iso/c76 on vms trough admin vlan
#            /kvm/t store ks, and scripts for vms
#
# installation process :
#    - first, vms are created from a template ks with only one interface on "admin" lan
#    - second, additionnal network are created through virsh on host and ssh on vms

#-------------------------------config-------------------------------------------------

# VLAN declaration : all those VLANs will be "created" on back to back cable between the 2 hosts (can be more, but will need a switch or script adaptation to manage a ring of back to back cables open with spt)
# admin (adm) is supposed to be the one used to administrate vm from hosts : it will be the one used to ssh root on vm, mount nfs
# verif : # ip a | grep ': br2_' | sed -e 's/group.*$//'
#
# full  abreviated             interface on host
# vlan    vlan                 to create the vlan (do not use _ in short names, to be compatible with dns)
# name    name  @ip res vlanid bridge intf onto
# -------+---+---------+------+-----

$num2=$num+1;
$num220=210+10*$num;
$eno="eno".$num2;


@interfaces=(
    [ 'admin'                ,'adm'   ,'192.168.2'.$num2.'0',$num220+0,$eno ],
    [ 'intern'               ,'int'   ,'192.168.2'.$num2.'1',$num220+1,$eno ],
    [ 'ingres'               ,'ing'   ,'192.168.2'.$num2.'2',$num220+2,$eno ],
    [ 'esb'                  ,'esb'   ,'192.168.2'.$num2.'3',$num220+3,$eno ],
    [ 'storage'              ,'sto'   ,'192.168.2'.$num2.'4',$num220+4,$eno ],

    [ 'cluster-dmz'          ,'cld'   ,'192.168.2'.$num2.'5',$num220+5,$eno ],
    [ 'cluster-load-balancer','cll'   ,'192.168.2'.$num2.'6',$num220+6,$eno ],
    [ 'cluster-data-store'   ,'cls'   ,'192.168.2'.$num2.'7',$num220+7,$eno ],
    );

# P1 runs on e1+e2, P2 on e2+e3 and P3 on e3+e1
#       P1 P2 P3
@serv1=( 1, 2, 3);
@serv2=( 2, 3, 1);
@nfss= ( 1, 3, 2);

# hosts (name & host.id)
$me1='e'.$serv1[$num-1];
$me2='e'.$serv2[$num-1];
@machines=(
    [ $me1,1 ],
    [ $me2,2 ]
    );

# VMs : full name, abr name, nb_core, ram, disk, host.id, vlans, distro, prefered host...
@vms= (
    [ 'dmz-a'          ,'da',1,1,2,101, ['int','cld']            , 'c76', $me1 ],
    [ 'dmz-b'          ,'db',1,1,2,102, ['int','cld']            , 'c76', $me2 ],
    [ 'load-balancer-a','la',1,1,2,111, ['int','ing','cll','sto'], 'c76', $me1 ],
    [ 'load-balancer-b','lb',1,1,2,112, ['int','ing','cll','sto'], 'c76', $me2 ],
    [ 'fuse-a',         'fa',4,4,8,121, ['int','ing','esb']      , 'c76', $me1 ],
    [ 'fuse-b',         'fb',4,4,8,122, ['int','ing','esb']      , 'c76', $me2 ],
    [ 'broker-a',       'ba',2,2,4,131, ['esb','sto']            , 'c76', $me1 ],
    [ 'broker-b',       'bb',2,2,4,132, ['esb','sto']            , 'c76', $me2 ],
    [ 'data-store-a',   'sa',1,1,2,141, ['sto','cls']            , 'c76', $me1 ],
    [ 'data-store-b',   'sb',1,1,2,142, ['sto','cls']            , 'c76', $me2 ],
    [ 'tools',          'to',1,1,20,100,[]                       , 'c76', $me2 ]
    );

# global settings for NFS & NTP
$admin_network='192.168.'.$num220;
$nfs_host_id=$nfss[$num-1];

# ---------------------------------code-----------------------------------------------

# TODO : adding the capability to create pure level 2 vlans with no @ip on host (when there is no need, and normally excepted for admin, there should no be any need)
open FF,">hosts";
foreach $m (@machines)
{
    ($mach,$nm)=@{$m};
    open F,">interfaces_$mach";
    foreach $i (@interfaces)
    {
	($name,$id,$net,$vid,$bri)=@{$i};
	print F "# machine $mach, interface $name\n";
	print F "\
iface $bri.$vid inet manual
 vlan-raw-device $bri

auto br_${num}_$id
iface br_${num}_$id inet static
 address $net.$nm/24
 bridge_ports $bri.$vid
 bridge_stp on
 bridge_maxwait 10

";	 
	print FF "$net.$nm ${mach}-${name} $mach$id\n";
	# ht for fast access to vlan info
	unless (exists $ht_vlan{$id})
	{
	    $ht_vlan{$id}{'name'}=$name;
	    $ht_vlan{$id}{'addr'}=$net;
	    $ht_vlan{$id}{'hosts'}="\n# hosts on VLAN $id ($name)\n";
	}
    }
    close F;
    print FF "\n";
}
close FF;

# creation of ks + virt install associated
open F,"../ks.template";
read F,$tp,100000;
close F;

$lines_adm="# addresses of VMs on admin network\n";
open K,">virt-installs";
open KK,">virt-kill";
open KL,">virt-start";
open KS,">virt-stop";
foreach $v (@vms)
{
    ($name,$nv,$vcpu,$ram,$disk,$id,$nets,$dist,$host)=@{$v};
    $ram*=1024;
    # iterate on lans
    $lst="# addresses of $name on its admin network\n";
    $line="$admin_network.$id $nv ${nv}adm ${name}-admin\n";
    $lst.=$line;
    $lines_adm.=$line;
    foreach $n (@{$nets})
    {
	$addr=$ht_vlan{$n}{'addr'};
	$lname=$ht_vlan{$n}{'name'};
	$line="$addr.$id ${name}-${lname} ${nv}$n\n";
	# let's avoid doubles
	#$lst.=$line;
	$ht_vlan{$n}{'hosts'}.=$line;
    }
    open F,">$nv.ks";
    $ks=$tp;
    &repl('dist',$dist);
    &repl('host.id',$id);
    &repl('hostname',$nv);
    &repl('host_id_nfs',$nfs_host_id);
    &repl('res_admin',$admin_network);
    &repl('hosts',$lst);
    print F $ks;
    close F;
    print K "virt-install --os-type=linux --os-variant=rhel7 --location=/mnt/iso/$dist --vcpus $vcpu --ram $ram --name ${nv}${num} --graphics none --noautoconsole --network bridge=br_${num}_adm --disk /kvm/vms/${nv}${num}.img,size=$disk --arch x86_64 --virt-type kvm --initrd-inject=/kvm/t/kvm_automation_scripts/p${num}/$nv.ks --extra-args 'console=ttyS0,115200n8 serial ks=file://$nv.ks' # on $host\n";
    print KK "virsh destroy ${nv}${num}; virsh undefine ${nv}${num} --remove-all-storage; rm -f /kvm/vms/${nv}${num}.img # on $host\n";
    print KL "virsh start ${nv}${num} # on $host\n";
    print KS "((ssh root\@${nv}${num} shutdown -h now)& sleep 3;virsh shutdown ${nv}${num}; sleep 3; virsh destroy ${nv}${num})& # on $host\n";
};
close K;
close KK;
close KL;
close KS;

# list all hosts for each vlan
open F,">vm_hosts";
print F "\n",$lines_adm;
foreach $vlan (sort(keys %ht_vlan))
{
    next if $vlan eq 'adm';
    print F $ht_vlan{$vlan}{'hosts'};
}
close F;

# complement of hosts for each vm +
# post-post install of additionnal interfaces to vms (interfaces different from adm)
foreach $v (@vms)
{
    ($name,$nv,$vcpu,$ram,$disk,$id,$nets,$dist,$host)=@{$v};
    $st="# Addresses of VMs on LANs shared with $name\n";
    open F,">post_$nv.sh";
    print F "#!/bin/bash\n\n";
    print F "# --- stop the VM (if not the case already) ---\n echo stopping $nv${num} \n virsh shutdown ${nv}${num}\n sleep 3\n\n";
    print F "# --- QEMU image mount ----\n echo 'mounting qemu img'\n modprobe nbd max_part=8\n qemu-nbd -c /dev/nbd0 /kvm/vms/${nv}${num}.img\n partx -a /dev/nbd0 \n mkdir /tmp/img \n mount /dev/nbd0p1 /tmp/img \n\n";
    $eth=1;
    foreach $vlan (@{$nets})
    {
	$st.=$ht_vlan{$vlan}{'hosts'};
	print F "# ---- KVM add intf for vlan $vlan ----\n virsh attach-interface ${nv}${num} bridge br_${num}_$vlan --model virtio --config\n";
	print F " mac=`virsh domiflist ${nv}${num} | grep br_${num}_$vlan | sed -e 's/^.*  *//' | dd conv=ucase` \n";
	print F " cat <<EOF > /tmp/img/etc/sysconfig/network-scripts/ifcfg-eth$eth\n";
	print F "NAME=\"eth$eth\"\n";
	print F "DEVICE=\"eth$eth\"\n";
	print F "HWADDR=\"\$mac\"\n";
	print F "ONBOOT=\"yes\"\n";
	print F "TYPE=\"Ethernet\"\n";
	print F "IPADDR=\"",$ht_vlan{$vlan}{'addr'},'.',"$id\"\n";
	print F "PREFIX=\"24\"\n";
	print F "NETMASK=\"255.255.255.0\"\n";
	print F "BOOTPROTO=\"none\"\n";
	print F "IPV6INIT=\"no\"\n";
	print F "EOF\n\n";

	# increment eth number
	$eth++;
    }
    &insert("$nv.ks","__hosts__",$st);
    print F "\n# ---- Unmount image ----\n echo 'dismounting qemu img'\n umount /tmp/img \n qemu-nbd -d /dev/nbd0 \n";
    print F "\n# ---- restart the VM ----\n echo starting $nv${num} \n virsh start ${nv}${num}\n";
    close F;
}

#---------------------------------annexes-----------------------------------------------

sub repl
{
    my ($src,$dst)=@_;
    $ks=~s/\(\($src\)\)/$dst/msg;
}

sub insert
{
    my ($file,$pattern,$more)=@_;
    open FR,$file;
    read FR,$st,100000;
    close FR;
    $st=~s/$pattern/$more/s;
    open FW,">$file";
    print FW $st;
    close FW;
}    
       
# 
# ----- disable host key checking for ssh ----
# cd ~/.ssh/;touch config;chmod 400 config;echo "Host *" > config ; echo "  StrictHostKeyChecking no" >> config; echo "  UserKnownHostsFile=/dev/null" >> config
#
#  ----- links on host -----
#  for a in *ks; do (cd ../..; ln -s kvm_automation_scripts/run/$a .); done
#
# ----- NMAP ----
# net=220; while (( $net <= 227 )); do echo "===== on net $net =====";((net=$net+1)); nmap -sn 192.168.$net.3-254 | grep "scan report"; echo; done

# ifup ici pour P2 (230)
# grep 'iface eno[1234].23[0-9]' /etc/network/interfaces | awk '{print "ifup " $2}'

