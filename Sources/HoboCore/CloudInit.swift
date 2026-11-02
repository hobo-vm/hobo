import Foundation

/// The NoCloud seed that applies the Vagrant conventions to a Linux guest on its first boot:
/// `vagrant`/`vagrant` with passwordless sudo and the insecure keys, password SSH, and no
/// automatic updates. It is attached (as a `cidata` ISO) only while `create` runs; cleanup then
/// disables cloud-init, so later boots and clones never re-run it.
public enum CloudInit {
    public static let volumeName = "cidata"

    /// The seed's files, by name.
    public static func seed(hostname: String, macAddress: String) -> [String: String] {
        [
            "meta-data": metaData(hostname: self.hostname(for: hostname)),
            "user-data": userData,
            "network-config": networkConfig(macAddress: macAddress),
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
    static var userData: String {
        let username = Conventions.username
        return """
        #cloud-config
        users:
          - name: \(username)
            gecos: \(Conventions.fullName)
            groups: [adm, sudo]
            shell: /bin/bash
            sudo: "ALL=(ALL) NOPASSWD:ALL"
            lock_passwd: false
            plain_text_passwd: \(Conventions.password)
            ssh_authorized_keys:
        \(Conventions.insecurePublicKeys.map { "      - \($0)" }.joined(separator: "\n"))
        ssh_pwauth: true
        write_files:
          - path: /etc/apt/apt.conf.d/99hobo-no-automatic-updates
            content: |
              APT::Periodic::Update-Package-Lists "0";
              APT::Periodic::Unattended-Upgrade "0";
          # The kernel console on the VM's serial port too, which the host logs to console.log.
          - path: /etc/default/grub.d/99-hobo-console.cfg
            content: |
              GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0"
        runcmd:
          - [update-grub]

        """
    }

    /// DHCP keyed by MAC rather than the default DUID: macOS's bootpd records the client ID it is
    /// sent, and Hobo finds a VM's lease by its MAC (`DHCPLeases`).
    static func networkConfig(macAddress: String) -> String {
        """
        version: 2
        ethernets:
          primary:
            match:
              macaddress: "\(macAddress.lowercased())"
            dhcp4: true
            dhcp-identifier: mac

        """
    }

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
