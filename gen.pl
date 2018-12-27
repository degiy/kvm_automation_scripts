#!/bin/perl

# script de génération du fichier /etc/network/interfaces pour debian/stretch

# nom     abr  @ip res  vlanid intf br
# -------+---+---------+------+-----

@interfaces=(
    [ 'admin','adm','192.168.220',220,'eno2' ],
    [ 'interne','int','192.168.221',221,'eno2' ],
    [ 'ingres','ing','192.168.222',222,'eno2' ],
    [ 'esb','esb','192.168.223',223,'eno2' ],
    [ 'storage','sto','192.168.224',224,'eno2' ],

    [ 'cluster_dmz','cl_dmz','192.168.225',225,'eno2' ],
    [ 'cluster_load_balancer','cl_lb','192.168.226',226,'eno2' ],
    [ 'cluster_data_store','cl_ds','192.168.227',227,'eno2' ],
    );

# hotes
@machines=(
    [ 'e1',1 ],
    [ 'e2',2 ]
    );

# a faire : prevoir des bridges sans ip sur l'hote (ex : pour réseaux cluster ou internes)
open FF,">hosts";
foreach $m (@machines)
{
    ($mach,$nm)=@{$m};
    open F,">interfaces_$mach";
    foreach $i (@interfaces)
    {
	($nom,$id,$res,$vid,$bri)=@{$i};
	print F "# machine $mach, interface $nom\n";
	print F "\
iface $bri.$vid inet manual
 vlan-raw-device $bri

auto br_$id
iface br_$id inet static
 address $res.$nm/24
 bridge_ports $bri.$vid
 bridge_stp on
 brdige_maxwait 10

";	 
	print FF "$res.$nm ${mach}_${nom} $mach$id\n";  
    }
    close F;
    print FF "\n";
}
close FF;

# VMs : nom, abr, nb_core, ram, disk, host.id, vlans, distribution...
@vms= (
    [ 'dmz_a','da',2,2,2,101, ['int','cl_dmz'], 'c76' ],
    [ 'dmz_b','db',2,2,2,102, ['int','cl_dmz'], 'c76' ],
    [ 'load_balancer_a','la',1,1,2,111, ['int','ing','cl_lb'], 'c76' ],
    [ 'load_balancer_b','lb',1,1,2,112, ['int','ing','cl_lb'], 'c76' ],
    [ 'fuse_a','fa',4,8,4,121, ['int','ing','esb'], 'c76' ],
    [ 'fuse_b','fb',4,8,4,122, ['int','ing','esb'], 'c76' ],
    [ 'broker_a','ba',2,4,2,131, ['esb','sto'], 'c76' ],
    [ 'broker_b','bb',2,4,2,132, ['esb','sto'], 'c76' ],
    [ 'data_store_a','sa',1,1,2,141, ['sto','cl_ds'], 'c76' ],
    [ 'data_store_b','sb',1,1,2,142, ['sto','cl_ds'], 'c76' ]
    );

# creation des ks + virt install associés
open F,"../ks.template";
read F,$tp,100000;
close F;

open K,">virt-installs";
open KK,">virt-kill";
foreach $v (@vms)
{
    ($nom,$nv,$vcpu,$ram,$disk,$id,$res,$dist)=@{$v};
    $ram*=1024;
    open F,">$nv.ks";
    $ks=$tp;
    &repl('dist',$dist);
    &repl('host.id',$id);
    &repl('hostname',$nv);
    print F $ks;
    close F;
    print K "virt-install --os-type=linux --os-variant=rhel7 --location=/mnt/iso/$dist --vcpus $vcpu --ram $ram --name $nv --graphics none --noautoconsole --network bridge=br_adm --disk /kvm/vms/$nv.img,size=$disk --arch x86_64 --virt-type kvm --initrd-inject=/kvm/t/$nv.ks --extra-args 'console=ttyS0,115200n8 serial ks=file://$nv.ks'\n";
    print KK "virsh destroy $nv; virsh undefine $nv; rm -f /kvm/mvs/$nv.img\n";
};
close K;
close KK;

sub repl
{
    my ($src,$dst)=@_;
    $ks=~s/\(\($src\)\)/$dst/ms;
}


   
