/// The starter `Boxcar` written by `hobo init`.
public enum BoxcarTemplate {
    public static func render(box: String) -> String {
        """
        # vim: ft=toml
        # Hobo Boxcar: https://github.com/ggal625/hobo

        box    = "\(box)"
        cpus   = 4
        memory = "8GB"
        disk   = "80GB"
        gui    = false

        # [[forwarded_port]]
        # guest = 8080
        # host  = 8080

        # [[provision]]
        # type   = "shell"
        # inline = "echo hello from $(hostname)"
        # run    = "once"

        """
    }
}
