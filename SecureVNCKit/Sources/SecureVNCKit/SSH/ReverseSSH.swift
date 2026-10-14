/// The other machine's side of a reverse shell: its own `ssh` client connects to this phone, and a login shell
/// on a pty is wired to the session through a fifo. One connection per run; no sshd or authorized_keys there.
public enum ReverseSSH {
    public static func serverCommand(phone: String, port: Int) -> String {
        "mkfifo /tmp/f; ssh -p\(port) \(phone) </tmp/f | script -q /dev/null zsh -l >/tmp/f"
    }
}
