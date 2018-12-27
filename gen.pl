#!/usr/bin/perl

# this script generate several files :
#
# - interfaces_mach_x : lines to add to /etc/network/interfaces to make bridges interfaces on vlan to give host and vms vlans (works for a debian/stretch kvm host). One file for each "x" host (need to use the same intf config : ex : eno2 for back to back comm)
# - hosts : /etc/hosts completion with names for kvm host on different vlans (ex : server_a_vlan_x)
# - vm_hosts : /etc/hosts completion with names for kvm vms on different vlans
# - vm_z.ks : ks to create vm "z"
# - virt-installs : script to launch all the virt-install cmds
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

#--------------------------------------------------------------------------------
# VLAN declaration : all those VLANs will be "created" on back to back cable between the 2 hosts (can be more, but will need a switch or script adaptation to manage a ring of back to back cables open with spt)
# admin (adm) is supposed to be the one used to administrate vm from hosts : it will be the one used to ssh root on vm, mount nfs
# verif : # ip a | grep ': br_' | sed -e 's/group.*$//'
#
# full  abreviated             interface on host
# vlan    vlan                 to create the vlan
# name    name  @ip res vlanid bridge intf onto
# -------+---+---------+------+-----

@interfaces=(
    [ 'admin'                ,'adm'   ,'192.168.220',220,'eno2' ],
    [ 'intern'               ,'int'   ,'192.168.221',221,'eno2' ],
    [ 'ingres'               ,'ing'   ,'192.168.222',222,'eno2' ],
    [ 'esb'                  ,'esb'   ,'192.168.223',223,'eno2' ],
    [ 'storage'              ,'sto'   ,'192.168.224',224,'eno2' ],

    [ 'cluster_dmz'          ,'cl_dmz','192.168.225',225,'eno2' ],
    [ 'cluster_load_balancer','cl_lb' ,'192.168.226',226,'eno2' ],
    [ 'cluster_data_store'   ,'cl_ds' ,'192.168.227',227,'eno2' ],
    );

# hosts (name & host.id)
@machines=(
    [ 'e1',1 ],
    [ 'e2',2 ]
    );

# VMs : full name, abr name, nb_core, ram, disk, host.id, vlans, distro, prefered host...
@vms= (
    [ 'dmz_a'          ,'da',2,2,2,101, ['int','cl_dmz']     , 'c76', 'e1' ],
    [ 'dmz_b'          ,'db',2,2,2,102, ['int','cl_dmz']     , 'c76', 'e2' ],
    [ 'load_balancer_a','la',1,1,2,111, ['int','ing','cl_lb'], 'c76', 'e1' ],
    [ 'load_balancer_b','lb',1,1,2,112, ['int','ing','cl_lb'], 'c76', 'e2' ],
    [ 'fuse_a',         'fa',4,8,4,121, ['int','ing','esb']  , 'c76', 'e1' ],
    [ 'fuse_b',         'fb',4,8,4,122, ['int','ing','esb']  , 'c76', 'e2' ],
    [ 'broker_a',       'ba',2,4,2,131, ['esb','sto']        , 'c76', 'e1' ],
    [ 'broker_b',       'bb',2,4,2,132, ['esb','sto']        , 'c76', 'e2' ],
    [ 'data_store_a',   'sa',1,1,2,141, ['sto','cl_ds']      , 'c76', 'e1' ],
    [ 'data_store_b',   'sb',1,1,2,142, ['sto','cl_ds']      , 'c76', 'e2' ]
    );

# global settings for NFS & NTP
$admin_network='192.168.220';
$nfs_host_id='1';

# --------------------------------------------------------------------------------

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

auto br_$id
iface br_$id inet static
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
    $lst.="$admin_network.$id $nv ${nv}adm ${name}_admin\n";
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
    print K "virt-install --os-type=linux --os-variant=rhel7 --location=/mnt/iso/$dist --vcpus $vcpu --ram $ram --name $nv --graphics none --noautoconsole --network bridge=br_adm --disk /kvm/vms/$nv.img,size=$disk --arch x86_64 --virt-type kvm --initrd-inject=/kvm/t/$nv.ks --extra-args 'console=ttyS0,115200n8 serial ks=file://$nv.ks' # on $host\n";
    print KK "virsh destroy $nv; virsh undefine $nv; rm -f /kvm/mvs/$nv.img # on $host\n";
    print KL "virsh start $nv # on $host\n";
    print KS "((ssh root\@$nv shutdown -h now); sleep 5;virsh destroy $nv)& # on $host\n";
};
close K;
close KK;
close KL;
close KS;

# list all hosts for each vlan
open F,">vm_hosts";
foreach $vlan (sort(keys %ht_vlan))
{
    print F $ht_vlan{$vlan}{'hosts'};
}
close F;

# complement of hosts for each vm
foreach $v (@vms)
{
    $st="# Addresses of VMs on LANs shared with $name\n";
    ($name,$nv,$vcpu,$ram,$disk,$id,$nets,$dist,$host)=@{$v};
    foreach $vlan (@{$nets})
    {
	$st.=$ht_vlan{$vlan}{'hosts'}
    }
    &insert("$nv.ks","__hosts__",$st);
}

sub repl
{
    my ($src,$dst)=@_;
    $ks=~s/\(\($src\)\)/$dst/msg;
}

sub insert
{
    my ($file,$pattern,$more)=@_;
    open F,$file;
    read F,$st,100000;
    close F;
    $st=~s/$pattern/$more/s;
    open F,">$file";
    print F $st;
    close F;
}    
       
# on hosts :
# disable host key checking for ssh
# cd ~/.ssh/;touch config;chmod 400 config;echo "Host 192.168.*" > config ; echo "  StrictHostKeyChecking no" >> config; echo "  UserKnownHostsFile=/dev/null" >> config
#  for a in *ks; do (cd ../..; ln -s kvm_automation_scripts/run/$a .); done
