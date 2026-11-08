import Foundation

/// The NoCloud seed that applies the guest conventions to a Linux guest on its first boot:
/// `hobo`/`hobo` with passwordless sudo and the insecure key, password SSH, and no
/// automatic updates, plus the fstab line that mounts the VM's shares. It is attached (as a
/// `cidata` ISO) only while `create` runs; cleanup then disables cloud-init, so later boots and
/// clones never re-run it.
public enum CloudInit {
    public static let volumeName = "cidata"

    /// The virtio-fs tag a Linux VM's shares are all on, as one multiple-directory share, and
    /// where the guest mounts it: each share appears at `<shareMountPoint>/<name>`.
    public static let shareTag = "hobo"
    public static let shareMountPoint = "/mnt/hobo"

    /// The seed's files, by name, for the VM `vmName`. `uid` is the host user's, given to
    /// `hobo` so that shared files, which the guest sees with their host owner, are its own.
    public static func seed(vmName: String, uid: UInt32) -> [String: String] {
        [
            "meta-data": metaData(hostname: hostname(for: vmName)),
            "user-data": userData(uid: uid),
            "network-config": networkConfig,
        ]
    }

    /// A VM name may hold `_` and `.`, which a hostname label can't (`hostnamectl` rejects `_`, and
    /// a dot would split off a domain), so both become `-`.
    static func hostname(for name: String) -> String {
        let label = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return String(label.reversed().drop { $0 == "-" }.reversed())
    }

    static func metaData(hostname: String) -> String {
        """
        instance-id: hobo-\(UUID().uuidString.lowercased())
        local-hostname: \(hostname)

        """
    }

    /// `users` without `default` leaves out the image's own `ubuntu` user.
    static func userData(uid: UInt32) -> String {
        let username = Conventions.username
        return """
        #cloud-config
        users:
          - name: \(username)
            uid: \(uid)
            gecos: \(Conventions.fullName)
            groups: [adm, sudo]
            shell: /bin/bash
            sudo: "ALL=(ALL) NOPASSWD:ALL"
            lock_passwd: false
            plain_text_passwd: \(Conventions.password)
            ssh_authorized_keys:
              - \(Conventions.insecurePublicKey)
        ssh_pwauth: true
        write_files:
          - path: /etc/apt/apt.conf.d/99hobo-no-automatic-updates
            content: |
              APT::Periodic::Update-Package-Lists "0";
              APT::Periodic::Unattended-Upgrade "0";
          # The kernel console on the VM's serial port too, which the host logs to console.log, and
          # a Terminus 10x18 font from the start of boot. The text console runs at 1920x1200 or at
          # the window's size in points (about 1440x900): 8x16 is tiny at the first, 16x32 huge at
          # the second.
          - path: /etc/default/grub.d/99-hobo-console.cfg
            content: |
              GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0 fbcon=font:TER10x18"
          # Shares, mounted on every boot: the device is always attached, so shares added later
          # appear with nothing changed in the guest. Written directly rather than through
          # cloud-init's mounts module, which would read a bare name like this tag as a device.
          - path: /etc/fstab
            append: true
            content: |
              \(shareTag) \(shareMountPoint) virtiofs defaults,nofail 0 0
        runcmd:
          - [mkdir, -p, \(shareMountPoint)]
          - [update-grub]
          # setupcon would otherwise load the 8x16 font back partway through boot. 10x20 is its
          # Terminus size closest to the kernel's 10x18.
          - [sed, -i, -e, 's/^FONTFACE=.*/FONTFACE="Terminus"/', -e, 's/^FONTSIZE=.*/FONTSIZE="10x20"/', /etc/default/console-setup]

        """
    }

    /// The NIC matched by driver, not MAC, so a clone with a new MAC still finds it (cloud-init is
    /// off by then, so nothing would rewrite this). DHCP keyed by MAC rather than the default DUID:
    /// macOS's bootpd records the client ID it is sent, and Hobo finds a VM's lease by its MAC
    /// (`DHCPLeases`); a DUID comes from `/etc/machine-id`, which a clone shares with its source.
    static let networkConfig = """
        version: 2
        ethernets:
          primary:
            match:
              driver: virtio_net
            dhcp4: true
            dhcp-identifier: mac

        """

    /// Run over SSH once the guest answers: waits for cloud-init to finish, then checks that the
    /// conventions took. `status --wait` exits 2 for a finished run with warnings, which is fine.
    public static let waitCommand = "cloud-init status --wait >/dev/null; test $? -ne 1 && sudo -n true"

    /// Root script run after recipe steps: drop caches, logs, history and temp files, disable
    /// cloud-init for every later boot, and TRIM so the freed blocks (and the zeros the image
    /// conversion wrote) return to the host.
    public static let cleanupScript = """
    cloud-init clean --logs
    touch /etc/cloud/cloud-init.disabled
    apt-get clean
    journalctl --rotate --vacuum-time=1s >/dev/null 2>&1
    find /var/log -type f \\( -name '*.gz' -o -name '*.[0-9]' \\) -delete 2>/dev/null
    rm -f /home/\(Conventions.username)/.bash_history /root/.bash_history
    rm -rf /tmp/hobo-* /var/tmp/* 2>/dev/null
    fstrim -a
    true

    """
}
