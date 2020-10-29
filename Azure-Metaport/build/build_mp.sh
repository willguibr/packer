#!/bin/bash -e
set -x
sudo apt-get -qq -y update
sudo apt-get -q -y install software-properties-common
sudo apt-get -q -y install python3-pip
if ! type -fp ansible > /dev/null ; then
  sudo pip3 install ansible
fi
tmpdir=$(mktemp -d)
match=$(grep --text --line-number '^#PAYLOAD:$' $0 | cut -d ':' -f 1)
payload_start=$((match + 1))
tail -n +$payload_start $0 | tar -C $tmpdir -xf -
pushd $tmpdir
ansible-playbook -i "localhost," -c local -e 'ansible_python_interpreter=/usr/bin/python3' -e '@vars_global.yaml' -e '@vars.yml' install.yml
popd
rm -rf $tmpdir
exit 0
#PAYLOAD:
install.yml                                                                                         0000664 0001750 0001751 00000023210 13707261724 012707  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 - hosts: localhost
  become: False

  tasks:
  - name: Get ubuntu groups
    command: groups ubuntu
    register: ubuntu_groups

  - set_fact:
      ubuntu_groups_list: "{{ ubuntu_groups.stdout.split(':')[1].split() }}"

  - name: Get ubuntu uid
    command: id -r -u ubuntu
    register: ubuntu_uid

  - name: Create mpadmin homedir
    file:
      state: link
      src: /home/ubuntu
      path: /home/mpadmin
      owner: ubuntu
      group: ubuntu
      mode: 0755
    become: true

  - name: Create mpadmin user
    user:
      name: mpadmin
      non_unique: yes
      uid: "{{ ubuntu_uid.stdout }}"
      group: ubuntu
      groups: "{{ ubuntu_groups_list }}"
      home: /home/mpadmin
      create_home: no
      shell: /bin/bash
    become: true

  - name: Allow mpadmin to have passwordless sudo
    lineinfile:
      dest: /etc/sudoers.d/mpadmin
      create: yes
      state: present
      regexp: '^mpadmin'
      line: 'mpadmin ALL=(ALL) NOPASSWD:ALL'
      validate: 'visudo -cf %s'
    become: true

  - name: Extract mpadmin user details
    shell: grep '^mpadmin:' /etc/passwd
    register: mpadmin_passwd_user

  - name: Remove mpadmin from passwd
    lineinfile:
      dest: /etc/passwd
      state: absent
      regexp: '^mpadmin:'
    become: true

  - name: Insert mpadmin user before ubuntu
    lineinfile:
      dest: /etc/passwd
      state: present
      line: "{{ mpadmin_passwd_user.stdout }}"
      insertbefore: '^ubuntu:'
    become: true

- hosts: localhost
  become: False
  remote_user: mpadmin

  vars:
    lxd_release: '{{ "bionic-updates" if ansible_distribution_release == "bionic" else "xenial-backports" }}'

  tasks:
  - name: Remove LXD old repo (deprecated)
    become: True
    file:
      path: /etc/apt/sources.list.d/ppa_ubuntu_lxc_stable_xenial.list
      state: absent
  - name: Clean apt cache
    become: True
    apt:
      autoclean: yes
  - name: Update apt cache
    become: True
    apt:
      update_cache: yes

  - name: Update package LXD
    become: True
    apt:
      name: lxd
      state: latest
      default_release: '{{ lxd_release }}'

  - name: Upgrade packages
    become: True
    apt:
      upgrade: dist
  - name: Install software packages
    become: True
    apt:
      name:
      - strongswan
      - libstrongswan-extra-plugins
      - unzip
      - dialog
      - python3-pip
      - figlet
      - tcpdump
      - iftop
      - htop
      - iputils-arping
      - sysstat
      - conntrack
      - mtr
      - netperf
      state: present
  - name: Remove unneeded packages
    become: True
    apt:
      name: ['bind9']
      state: absent

  - name: Add SSH authorized key
    become: false
    authorized_key:
      user: ubuntu
      state: present
      key: '{{ item }}'
    with_file:
    - ./host/metaport.pub

  - name: Forwarding related setup
    become: True
    sysctl:
      name: '{{ item.key }}'
      value: '{{ item.value }}'
    loop:
    - { key: 'net.ipv4.ip_forward', value: '1' }
    - { key: 'net.ipv4.conf.all.rp_filter', value: '0' }
    - { key: 'net.ipv4.conf.default.rp_filter', value: '0' }
    - { key: 'net.ipv4.conf.all.accept_local', value: '1' }
    - { key: 'net.ipv4.conf.default.accept_local', value: '1' }

  - name: Nullify ebtables executable
    become: True
    file:
      src: '/bin/true'
      dest: '/usr/local/sbin/ebtables'
      state: link

  - name: Disable metaport-conn-keeper service (deprecated)
    become: True
    ignore_errors: True
    command: systemctl disable metaport-conn-keeper
  - name: Stop metaport-conn-keeper service (deprecated)
    become: True
    ignore_errors: True
    service:
      name: metaport-conn-keeper
      state: stopped

  - name: Install metaport-conn-keeper files
    become: True
    copy:
      src: '{{ item.src }}'
      dest: '{{ item.dest }}'
      mode: 0755
    with_items:
    - { src: './keeper/metaport-conn-keeper.py', dest: '/usr/local/bin/metaport-conn-keeper.py' }
    - { src: './keeper/metaport-conn-keeper@.service', dest: '/lib/systemd/system/metaport-conn-keeper@.service' }
  - name: Restart metaport-conn-keeper service
    become: True
    service:
      name: metaport-conn-keeper@metaport-host
      state: restarted
      daemon_reload: yes
  - name: Enable metaport-conn-keeper service
    become: True
    command: systemctl enable metaport-conn-keeper@metaport-host # service.enabled WAR

  - name: Locate meta networks provided netplan file exists
    stat:
      path: /etc/netplan/99-meta.yaml
    register: meta_netplan

  - name: Download netplan-tui src dist
    get_url:
      url: 'https://s3.amazonaws.com/public.nsof.io/netplantui/netplan_tui.tgz'
      dest: '/tmp/netplan_tui.tar.gz'
    when: meta_netplan.stat.exists == True

  - name: Install netplan-tui
    become: True
    command: pip3 install -U /tmp/netplan_tui.tar.gz
    when: meta_netplan.stat.exists == True

  - name: Download metaport-cli src dist
    get_url:
      url: 'https://s3.amazonaws.com/public.nsof.io/metaportcli/metaport_cli.tgz'
      dest: '/tmp/metaport_cli.tar.gz'

  - name: Install metaport-cli
    become: True
    command: pip3 install -U /tmp/metaport_cli.tar.gz

  - name: Add Meta Networks login splash
    become: True
    copy:
      src: './host/z99-metaport-splash.sh'
      dest: '/etc/profile.d/'
      mode: 0755

  - name: Ensure relevant kernel modules loaded upon boot
    become: True
    lineinfile:
      dest: /etc/modules
      line: '{{ item }}'
    with_items: [ 'ip_vti', 'ipip', 'nf_nat_tftp', 'nf_nat_ftp', 'nf_nat_sip' ]
  - name: Load relevant kernel modules
    become: True
    modprobe:
      name: '{{ item }}'
    with_items: [ 'ip_vti', 'ipip', 'nf_nat_tftp', 'nf_nat_ftp', 'nf_nat_sip' ]

  - name: Copy apt.conf.d file to disable ubuntu's unattended upgrades
    become: True
    copy:
      src: './host/apt.conf.d_99-nsof'
      dest: '/etc/apt/apt.conf.d/99-nsof'

  - name: LXD init
    become: True
    command: lxd init --auto
  - name: Detect LXD network configuration
    command: lxc network get lxdbr0 ipv4.address
    ignore_errors: True
    register: result
  - name: LXD network setup
    command: >
      lxc network create lxdbr0 ipv4.address={{ lxdbr0_addr }} ipv4.nat=true
      ipv6.address=none
    when: result is failed
  - name: Copy LXD network config
    template:
      src: './host/lxd-network.yaml.j2'
      dest: '/tmp/lxd-network.yaml'
  - name: Configure LXD network
    shell: "cat /tmp/lxd-network.yaml | lxc network edit lxdbr0"
  - name: Detect LXD profile settings
    command: lxc profile device get default eth0 parent
    ignore_errors: True
    register: result
  - name: LXD setup profile's network
    command: lxc network attach-profile lxdbr0 default eth0 eth0
    when: result.stdout != "lxdbr0"
  - name: LXD service restart
    become: True
    service:
      name: lxd
      state: restarted
      daemon_reload: yes

  - name: Download ePoP image
    get_url:
      url: https://s3.amazonaws.com/public.nsof.io/lxd/nsof-bond-bionic.latest.tar.gz
      dest: ./nsof-bond.tgz
  - name: Delete former image (if exists)
    command: 'lxc image delete nsof-epop'
    ignore_errors: True
  - name: Import image into LXD
    command: 'lxc image import nsof-bond.tgz --alias nsof-epop'
  - name: Remove tmp image file
    file:
      state: absent
      path: ./nsof-bond.tgz

  - name: Test container presence
    command: 'lxc info epop1'
    ignore_errors: True
    register: result
  - name: Delete container
    command: 'lxc delete -f epop1'
    when: result is succeeded
  - name: Ensure /var/lib/epop exists
    become: True
    file:
      path: /var/lib/epop
      state: directory
      mode: 0777

  - name: compat, find bond's ipsec.conf
    find:
      paths: /var/lib/epop/ipsec.d
      patterns: 'ipsec.*.conf'
    register: bond_ipsec_conf
  - name: compat, change bond's existing "left=" to bond_addr
    become: True
    lineinfile:
      path: '{{ item.path }}'
      regexp: 'left='
      line: '  left={{ bond_addr }}'
    with_items: '{{ bond_ipsec_conf.files }}'

  - name: Start PoPAI container
    lxd_container:
      name: epop1
      state: started
      profiles: ['default']
      source:
        type: image
        alias: nsof-epop
      config:
        boot.autostart: 'true'
        user.user-data: |
          #cloud-config
          bootcmd:
          - mkdir -p /var/lib/bond/ipsec.d /var/lib/bond/ofs_work
          - (test -n "{{ vnf_play|default() }}" && touch /etc/nsof-bond/vnf-chain) || true
          mounts:
          - [ overlay, /usr/local/etc/ipsec.d, overlay, "lowerdir=/usr/local/etc/ipsec.d,upperdir=/var/lib/bond/ipsec.d,workdir=/var/lib/bond/ofs_work" ]
          write_files:
          - content: "BOND_ADDR={{ bond_addr }}\nVNF_ADDR={{ vnf_addr }}\nBOND_VIP={{ bond_vip }}\n"
            path: /etc/nsof-bond.env
            permissions: '0755'
      devices:
        eth0:
          type: nic
          nictype: bridged
          name: eth0
          parent: lxdbr0
          ipv4.address: '{{ bond_addr }}'
        ipsecdir:
          type: disk
          path: /var/lib/bond
          source: /var/lib/epop

  - name: Delete the epop image
    command: 'lxc image delete nsof-epop'

  - name: Install net-setup files
    become: True
    template:
      src: '{{ item.src }}'
      dest: '{{ item.dest }}'
      mode: 0755
    with_items:
    - { src: './host/net-setup.py', dest: '/usr/local/bin/nsof-net-setup.py' }
    - { src: './host/net-setup.service.j2', dest: '/lib/systemd/system/nsof-net-setup.service' }
  - name: Restart net-setup service
    become: True
    service:
      name: nsof-net-setup
      state: restarted
      daemon_reload: yes
  - name: Enable net-setup service
    become: True
    command: systemctl enable nsof-net-setup # service.enabled WAR

- import_playbook: '{{ vnf_play|default("nop.yml") }}'
                                                                                                                                                                                                                                                                                                                                                                                        nop.yml                                                                                             0000664 0001750 0001751 00000000046 13707261724 012037  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 - hosts: localhost
  gather_facts: no
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          install_vnf-ipsec.yml                                                                               0000664 0001750 0001751 00000003606 13707261724 014670  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 - hosts: localhost
  become: False

  tasks:
  - name: Download vnf-ipsec gateway lxd image
    get_url:
      url: https://s3.amazonaws.com/public.nsof.io/lxd/nsof-vnf-ipsec.latest.tar.gz
      dest: ./nsof-vnf-ipsec.tgz
  - name: Delete former image (if exists)
    command: 'lxc image delete nsof-vnf-ipsec'
    ignore_errors: True
  - name: Import image into LXD
    command: 'lxc image import nsof-vnf-ipsec.tgz --alias nsof-vnf-ipsec'
  - name: Remove tmp image file
    file:
      state: absent
      path: ./nsof-vnf-ipsec.tgz

  - name: Test container presence
    command: 'lxc info vnf-ipsec-gw1'
    ignore_errors: True
    register: result
  - name: Delete container
    command: 'lxc delete -f vnf-ipsec-gw1'
    when: result is succeeded

  - name: Ensure /var/lib/vnf-ipsec exists
    become: True
    file:
      path: /var/lib/vnf-ipsec
      state: directory
      mode: 0777
  - name: Create empty vnf-ipsec self.env if not exists
    copy:
      force: no
      dest: /var/lib/vnf-ipsec/self.env
      mode: 0666
      content: |
        IPSEC_PSK=
        IPSEC_REMOTE_IP=
        IPSEC_IKE=
        IPSEC_ESP=
        IPSEC_VIP=
        IKE_VERSION=
  - name: Start vnf-ipsec GW container
    lxd_container:
      name: vnf-ipsec-gw1
      state: started
      profiles: ['default']
      source:
        type: image
        alias: nsof-vnf-ipsec
      config:
        boot.autostart: 'true'
        user.user-data: |
          #cloud-config
          write_files:
          - content: "BOND_ADDR={{ bond_addr }}\nVNF_ADDR={{ vnf_addr }}\nBOND_VIP={{ bond_vip }}\n"
            path: /etc/nsof-bond.env
            permissions: '0755'
      devices:
        eth0:
          type: nic
          nictype: bridged
          name: eth0
          parent: lxdbr0
          ipv4.address: '{{ vnf_addr }}'
        envdir:
          type: disk
          path: /etc/nsof-vnf
          source: /var/lib/vnf-ipsec
                                                                                                                          install_vnf-dnat.yml                                                                                0000664 0001750 0001751 00000003404 13707261724 014507  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 - hosts: localhost
  become: False

  tasks:
  - name: Download vnf-dnat gateway lxd image
    get_url:
      url: https://s3.amazonaws.com/public.nsof.io/lxd/nsof-vnf-dnat.latest.tar.gz
      dest: ./nsof-vnf-dnat.tgz
  - name: Delete former image (if exists)
    command: 'lxc image delete nsof-vnf-dnat'
    ignore_errors: True
  - name: Import image into LXD
    command: 'lxc image import nsof-vnf-dnat.tgz --alias nsof-vnf-dnat'
  - name: Remove tmp image file
    file:
      state: absent
      path: ./nsof-vnf-dnat.tgz

  - name: Test container presence
    command: 'lxc info vnf-dnat-gw1'
    ignore_errors: True
    register: result
  - name: Delete container
    command: 'lxc delete -f vnf-dnat-gw1'
    when: result is succeeded

  - name: Ensure /var/lib/vnf-dnat exists
    become: True
    file:
      path: /var/lib/vnf-dnat
      state: directory
      mode: 0777
  - name: Create empty self.env if not exists
    copy:
      force: no
      dest: /var/lib/vnf-dnat/self.env
      mode: 0666
      content: |
        DNAT_IP=

  - name: Start vnf-dnat GW container
    lxd_container:
      name: vnf-dnat-gw1
      state: started
      profiles: ['default']
      source:
        type: image
        alias: nsof-vnf-dnat
      config:
        boot.autostart: 'true'
        user.user-data: |
          #cloud-config
          write_files:
          - content: "BOND_ADDR={{ bond_addr }}\nVNF_ADDR={{ vnf_addr }}\nBOND_VIP={{ bond_vip }}\n"
            path: /etc/nsof-bond.env
            permissions: '0755'
      devices:
        eth0:
          type: nic
          nictype: bridged
          name: eth0
          parent: lxdbr0
          ipv4.address: '{{ vnf_addr }}'
        envdir:
          type: disk
          path: /etc/nsof-vnf
          source: /var/lib/vnf-dnat
                                                                                                                                                                                                                                                            vars_global.yaml                                                                                    0000664 0001750 0001751 00000000206 13707261724 013675  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 lxdbr0_addr: 198.51.100.1/25
bond_subnet: 198.51.100.0/25
bond_addr: 198.51.100.126
vnf_addr: 198.51.100.125
bond_vip: 198.51.100.254
                                                                                                                                                                                                                                                                                                                                                                                          host/metaport.pub                                                                                   0000664 0001750 0001751 00000001336 13707261724 014043  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCuoe9cXxcjwCzZ2n+yEsvpZDBNeNh7T+WN5bA8qUL2+3zwnYEsUtw7CFRJr2fAQJhUmtYcL73wT1kd+EG7CWOj99P+3YJ4UK36IAjYcs+o48yA3eeYf/hhWeSSLUUeV3i/qcu0LkCUxbO5xU0Z/cDPWB1zjYveZrhLluT8f8d8Oe0CTXiNKiVtkm6EHJC2ev9mwInDdIGWGmdZYuPUrfJKE4cMn9JlH+Z1fkzngm0r9oXMlGMH/XDqosdGbqYf5CzoOtH5hlp9UO91TuZO9mebQSx9fZm6GRLCzHUdlE+SdTcDpSqVTYn96NMOEtxT26xAp71B5TkYmgrkekSsPON6uZq7LntCLMhBnHPNhrR6N2F/G38D5ptRSDWa38JnvuARdvAsZnejj/e4k8V+e/1ol7LBqLcwVC7Gu7g81ZZ9MBxsmy8GbS9HGql8zxVbsab3qiB2iIcOSDg/UggEJjjG8+ji2/2u+ILSH2LBIlkXxuuYi8UaxpuoH4OOysYnMu7kVRAoGh7XsL1KuFSoIY1bmWQMDSMoDt67T43SuP+hTSuICh7a8wJ+2yYcl5FbDSO5LCC8Oro5sKTBJpGu4/nn5OWeJOkkzqv+/AdojjsH/87CxL3K2JFSa1T9B17c+KLAjSP5bNHdJxPmRRl4ALEUYh3KGyLVpPyrCVJ6YZRGNw== metaport
                                                                                                                                                                                                                                                                                                  keeper/metaport-conn-keeper.py                                                                      0000775 0001750 0001751 00000005334 13707261724 016414  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 #!/usr/bin/python3
import logging
import subprocess
import time
import os


CONN_KEEPER_ATTEMPTS = int(os.environ.get('CONN_KEEPER_ATTEMPTS', '7'))
CONN_KEEPER_INTERVAL = int(os.environ.get('CONN_KEEPER_INTERVAL', '60'))
CONN_KEEPER_CONN_NAME = os.environ.get('CONN_KEEPER_CONN_NAME', 'metaport-host')

LOG = logging.getLogger(__name__)


def _check_cmd(cmd):
    try:
        output = subprocess.check_output(cmd.split())
    except subprocess.CalledProcessError as e:
        LOG.info('Command %s failed with retcode %d', cmd, e.returncode)
        return None
    return str(output.decode())


class ConnKeeper(object):
    def __init__(self, conn):
        self._conn = conn
        # assure strongswan service is started
        self._strongswan_service('start')

    @staticmethod
    def _strongswan_service(verb):
        cmd = 'systemctl %s strongswan' % (verb,)
        if _check_cmd(cmd) is None:
            LOG.fatal('Failed to %s strongswan', verb)

    def _conn_up(self):
        return _check_cmd('ipsec up %s' % (self._conn,))

    def _conn_check(self):
        cmd = 'ipsec status %s' % (self._conn,)
        out = _check_cmd(cmd)
        if out is None:
            return -1
        elif 'no match' in out:
            return 0
        return 1

    def run(self):
        ATTEMPTS = CONN_KEEPER_ATTEMPTS
        last_errs = []
        while True:
            time.sleep(CONN_KEEPER_INTERVAL)

            ret = self._conn_check()
            LOG.debug('_conn_check returned %d', ret)
            if ret > 0:
                # success, reset last error list
                last_errs = []
                continue

            last_errs.insert(0, ret)
            last_errs = last_errs[:ATTEMPTS]

            if sum(last_errs) == -ATTEMPTS:
                msg = 'Failed to execute "ipsec" for %d attempts, ' \
                      'restarting strongswan service' % (ATTEMPTS,)
                LOG.warning(msg)
                self._strongswan_service('restart')
                last_errs = []
            elif len(last_errs) == ATTEMPTS:
                msg = 'Conn "%s" not found or ipsec failed for %d attempts, ' \
                      'try setting the conn up' % (self._conn, ATTEMPTS)
                LOG.warning(msg)
                if self._conn_up() is None:
                    LOG.warning('ipsec up failure, restarting strongswan')
                    self._strongswan_service('restart')
                last_errs = []


if __name__ == '__main__':
    logfmt = "%(name)s[%(process)d]: %(levelname)s %(message)s"
    logging.basicConfig(level=logging.DEBUG, format=logfmt)
    try:
        keeper = ConnKeeper(CONN_KEEPER_CONN_NAME)
        keeper.run()
    except Exception:
        LOG.exception('Failed with unknown exception')
        raise
                                                                                                                                                                                                                                                                                                    keeper/metaport-conn-keeper@.service                                                                0000664 0001750 0001751 00000000505 13707261724 017514  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 [Unit]
Description=MetaPort IPSec Conn Keeper
After=strongswan.service

[Service]
Type=simple
Environment=CONN_KEEPER_INTERVAL=30
Environment=CONN_KEEPER_ATTEMPTS=6
Environment=CONN_KEEPER_CONN_NAME=%i
ExecStart=/usr/bin/python3 /usr/local/bin/metaport-conn-keeper.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
                                                                                                                                                                                           host/net-setup.py                                                                                   0000664 0001750 0001751 00000011056 13707261724 013776  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 import subprocess
import logging
import os
import re
import time


log = logging.getLogger('nsof-net-setup')
BOND_LXD_IP = os.environ.get('BOND_LXD_IP')
BOND_LXD_SUBNET = os.environ.get('BOND_LXD_SUBNET')
LXD_BR_DEV = 'lxdbr0'
BOND_RT_TABLE = '110'
IPTABLES_CMD_COMMON = ['/sbin/iptables', '-w', '5']
BOND_CHAIN = 'NSOF-BOND'


def ip_call(*args):
    cmd = ('/sbin/ip',) + args
    return subprocess.call(cmd)


def ip_check_call(*args):
    cmd = ('/sbin/ip',) + args
    subprocess.check_call(cmd)


def ip_check_output(*args):
    cmd = ('/sbin/ip',) + args
    return str(subprocess.check_output(cmd).decode())


def add_route(table, *rt):
    cmd = ('route', 'add', 'table', table) + rt
    ip_check_call(*cmd)


def iptables_call(*args):
    cmd = IPTABLES_CMD_COMMON + list(args)
    return subprocess.call(cmd)


def iptables_check_call(*args):
    cmd = IPTABLES_CMD_COMMON + list(args)
    return subprocess.check_call(cmd)


def _get_dev_from_route(*args):
    try:
        o = ip_check_output(*args)
        rt = o.splitlines()[0]
        m = re.search('.*dev ([^ ]*) .*', rt)
        return m.group(1)
    except:
        return None


def get_bond_rt_dev():
    return _get_dev_from_route('route', 'get', BOND_LXD_IP)


def get_main_dev():
    return _get_dev_from_route('route', 'show', '0.0.0.0/0')


def setup_routing_to_bond(main_dev):
    # Traffic arriving at our host which is not destined to the host itself
    # (i.e. caught by 'local' routes) needs to be forwarded to the bond
    # container.
    # In order to make this apply to incoming traffic only, we place the
    # routes in a designated routing table and use an ip rule to reach it
    # only on incoming traffic (iif == eth0)

    # Wait for route towards container to be available
    while get_bond_rt_dev() != LXD_BR_DEV:
        time.sleep(1)

    # Add rule pointing towards bond table
    PREF = '110'  # after local (0) and before main (32766)
    ip_call('rule', 'del', 'pref', PREF)
    ip_check_call('rule', 'add', 'pref', PREF, 'iif', main_dev, 'lookup',
                  BOND_RT_TABLE)

    # Add routes to bond table
    ip_check_call('route', 'flush', 'table', BOND_RT_TABLE)
    add_route(BOND_RT_TABLE, 'default', 'via', BOND_LXD_IP)
    add_route(BOND_RT_TABLE, BOND_LXD_SUBNET, 'dev', LXD_BR_DEV, 'scope',
              'link')


def setup_bond_iptables_chain():
    iptables_call('-t', 'nat', '-N', BOND_CHAIN)
    iptables_check_call('-t', 'nat', '-F', BOND_CHAIN)
    rule = ('PREROUTING', '-j', BOND_CHAIN)
    if iptables_call('-t', 'nat', '-C', *rule) != 0:
        iptables_check_call('-t', 'nat', '-I', *rule)


def dnat_to_bond(main_dev, proto, port):
    rule = ('-t', 'nat', '-A', BOND_CHAIN,
            '-i', main_dev, '-m', 'addrtype', '--dst-type', 'LOCAL',
            '-p', proto, '-m', proto, '--dport', str(port),
            '-j', 'DNAT', '--to-destination', BOND_LXD_IP)
    iptables_check_call(*rule)


def snat_local_ipsec():
    # Using IKE on UDP port 500 for both external (client) and internal (epop)
    # connections seems to confuse several provider NAT implementations
    # (GCE, Azure).
    # SNAT local IKE to originate from port 11500.
    # Note: would have preferred to use sswan's 'leftikeport' - but that doesn't
    # seem to work.
    iptables_check_call('-t', 'nat', '-I', 'POSTROUTING', '-p', 'udp',
                        '-m', 'addrtype', '--src-type', 'LOCAL', '-m',
                        'udp', '--sport', '500', '--dport', '500', '-j',
                        'MASQUERADE', '--to-ports', '11500')


def flush_fwd_rules():
    # inserted by lxd, not needed as default policy is ACCEPT
    iptables_check_call('-t', 'filter', '-F', 'FORWARD')


def disable_v4_xfrm(devices):
    for dev in devices:
        subprocess.call(['sysctl', '-w',
                         'net.ipv4.conf.%s.disable_policy=1' % dev])
        subprocess.call(['sysctl', '-w',
                         'net.ipv4.conf.%s.disable_xfrm=1' % dev])


def main():
    log.info('Sending incoming traffic via %s', BOND_LXD_IP)

    main_dev = get_main_dev()

    # avoid v4 xfrm and policy on host routing interfaces
    # support tunnel unaffected as it uses v6
    disable_v4_xfrm([main_dev, LXD_BR_DEV])

    setup_routing_to_bond(main_dev)
    flush_fwd_rules()

    # DNAT DNS traffic destined to our host towards the bond container
    setup_bond_iptables_chain()
    dnat_to_bond(main_dev, 'tcp', 53)
    dnat_to_bond(main_dev, 'udp', 53)
    snat_local_ipsec()


if __name__ == '__main__':
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s %(name)s: <%(levelname)s> %(message)s'
    )
    main()
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  host/net-setup.service.j2                                                                           0000664 0001750 0001751 00000000466 13707261724 015323  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 [Unit]
Description=MetaPort Network Setup
After=lxd.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=BOND_LXD_IP={{ bond_addr }}
Environment=BOND_LXD_SUBNET={{ bond_subnet }}
ExecStart=/usr/bin/python3 /usr/local/bin/nsof-net-setup.py

[Install]
WantedBy=multi-user.target
                                                                                                                                                                                                          host/lxd-network.yaml.j2                                                                            0000664 0001750 0001751 00000000150 13707261724 015145  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 config:
  ipv4.address: "{{ lxdbr0_addr }}"
  ipv4.dhcp: "true"
  ipv4.nat: "true"
  ipv6.address: none
                                                                                                                                                                                                                                                                                                                                                                                                                        host/z99-metaport-splash.sh                                                                         0000775 0001750 0001751 00000000304 13707261724 015605  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 _CYAN='\033[1;36m'
_RESET='\033[0m'  # reset Color

figlet "Meta Networks: MetaPort"
metaport show -v
printf "${_CYAN}For Metaport onboarding and health checks use 'metaport --help'${_RESET}\n\n"
                                                                                                                                                                                                                                                                                                                            host/apt.conf.d_99-nsof                                                                             0000664 0001750 0001751 00000000047 13707261724 014637  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 APT::Periodic::Unattended-Upgrade "0";
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         vars.yml                                                                                            0000664 0001750 0001751 00000000017 13707261740 012212  0                                                                                                    ustar   ubuntu                          ubuntu                                                                                                                                                                                                                 __none: __none
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 