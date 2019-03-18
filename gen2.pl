#!/usr/bin/perl

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

@interfaces=(
    [ 'admin'                ,'adm'   ,'192.168.230',230,'eno2' ],
    [ 'intern'               ,'int'   ,'192.168.231',231,'eno2' ],
    [ 'ingres'               ,'ing'   ,'192.168.232',232,'eno2' ],
    [ 'esb'                  ,'esb'   ,'192.168.233',233,'eno2' ],
    [ 'storage'              ,'sto'   ,'192.168.234',234,'eno2' ],

    [ 'cluster_dmz'          ,'cld'   ,'192.168.235',235,'eno2' ],
    [ 'cluster_load_balancer','cll'   ,'192.168.236',236,'eno2' ],
    [ 'cluster_data_store'   ,'cls'   ,'192.168.237',237,'eno2' ],
    );

# hosts (name & host.id)
@machines=(
    [ 'e1',1 ],
    [ 'e2',2 ]
    );

# VMs : full name, abr name, nb_core, ram, disk, host.id, vlans, distro, prefered host...
@vms= (
    [ 'dmz_a'          ,'da',2,2,2,101, ['int','cld']            , 'c76', 'e1' ],
    [ 'dmz_b'          ,'db',2,2,2,102, ['int','cld']            , 'c76', 'e2' ],
    [ 'load_balancer_a','la',1,1,2,111, ['int','ing','cll']      , 'c76', 'e1' ],
    [ 'load_balancer_b','lb',1,1,2,112, ['int','ing','cll']      , 'c76', 'e2' ],
    [ 'fuse_a',         'fa',4,8,4,121, ['int','ing','esb','sto'], 'c76', 'e1' ],
    [ 'fuse_b',         'fb',4,8,4,122, ['int','ing','esb','sto'], 'c76', 'e2' ],
    [ 'broker_a',       'ba',2,4,2,131, ['esb','sto']            , 'c76', 'e1' ],
    [ 'broker_b',       'bb',2,4,2,132, ['esb','sto']            , 'c76', 'e2' ],
    [ 'data_store_a',   'sa',1,1,2,141, ['sto','cls']            , 'c76', 'e1' ],
    [ 'data_store_b',   'sb',1,1,2,142, ['sto','cls']            , 'c76', 'e2' ],
    [ 'tools',          'to',1,1,25,100,[]                       , 'c76', 'e2' ]
    );

# global settings for NFS & NTP
$admin_network='192.168.230';
$nfs_host_id='1';

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

auto br2_$id
iface br2_$id inet static
 address $net.$nm/24
 bridge_ports $bri.$vid
 bridge_stp on
 bridge_maxwait 10

";	 
	print FF "$net.$nm ${mach}_${name} $mach$id\n";
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
    $line="$admin_network.$id $nv ${nv}adm ${name}_admin\n";
    $lst.=$line;
    $lines_adm.=$line;
    foreach $n (@{$nets})
    {
	$addr=$ht_vlan{$n}{'addr'};
	$lname=$ht_vlan{$n}{'name'};
	$line="$addr.$id ${name}_${lname} ${nv}$n\n";
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
    print K "virt-install --os-type=linux --os-variant=rhel7 --location=/mnt/iso/$dist --vcpus $vcpu --ram $ram --name $nv --graphics none --noautoconsole --network bridge=br2_adm --disk /kvm/vms/$nv.img,size=$disk --arch x86_64 --virt-type kvm --initrd-inject=/kvm/t/$nv.ks --extra-args 'console=ttyS0,115200n8 serial ks=file://$nv.ks' # on $host\n";
    print KK "virsh destroy $nv; virsh undefine $nv --remove-all-storage; rm -f /kvm/vms/$nv.img # on $host\n";
    print KL "virsh start $nv # on $host\n";
    print KS "((ssh root\@$nv shutdown -h now)& sleep 3;virsh shutdown $nv; sleep 3; virsh destroy $nv)& # on $host\n";
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
    print F "# --- stop the VM (if not the case already) ---\n echo stopping $nv \n virsh shutdown $nv\n sleep 3\n\n";
    print F "# --- QEMU image mount ----\n echo 'mounting qemu img'\n modprobe nbd max_part=8\n qemu-nbd -c /dev/nbd0 /kvm/vms/$nv.img\n partx -a /dev/nbd0 \n mkdir /tmp/img \n mount /dev/nbd0p1 /tmp/img \n\n";
    $eth=1;
    foreach $vlan (@{$nets})
    {
	$st.=$ht_vlan{$vlan}{'hosts'};
	print F "# ---- KVM add intf for vlan $vlan ----\n virsh attach-interface $nv bridge br2_$vlan --model virtio --config\n";
	print F " mac=`virsh domiflist $nv | grep br2_$vlan | sed -e 's/^.*  *//' | dd conv=ucase` \n";
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
    print F "\n# ---- restart the VM ----\n echo starting $nv \n virsh start $nv\n";
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
