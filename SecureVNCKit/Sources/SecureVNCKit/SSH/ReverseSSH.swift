/// The other machine's side of a reverse connection: its own `ssh` client connects to this phone, and a login
/// shell on a pty is wired to the session through a fifo. No sshd or authorized_keys set up there.
public enum ReverseSSH {
    public static func serverCommand(phone: String, port: Int) -> String {
        "mkfifo /tmp/f; ssh -p\(port) \(phone) </tmp/f | script -q /dev/null zsh -l >/tmp/f"
    }

    /// Typed into that shell: an sshd on a random localhost port, as that user, authorizing only `phoneKey`; then
    /// the shell's pty goes raw and becomes a pipe to it. sshd reloads on SIGHUP, so a watcher stops it once the
    /// shell is gone. Its keepalives also end the shell soon after the phone's ssh is gone, freeing the retry loop.
    static func bootstrap(phoneKey: String) -> String {
        let key = phoneKey.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "'", with: "")
        let options = [
            "ListenAddress=127.0.0.1", "Port=$P", "AuthorizedKeysFile=$d/a", "PidFile=none", "UsePAM=no",
            "StrictModes=no", "PasswordAuthentication=no", "KbdInteractiveAuthentication=no",
            "ClientAliveInterval=2", "ClientAliveCountMax=3",
        ].map { "-o \($0)" }.joined(separator: " ")
        return " d=$(mktemp -d); P=$((RANDOM%20000+40000)); ssh-keygen -q -t ed25519 -N '' -f $d/h; echo '\(key)' >$d/a;"
            + " /usr/sbin/sshd -D -f /dev/null -h $d/h \(options) 2>/dev/null & s=$!;"
            + " (trap '' HUP; while kill -0 $$ 2>/dev/null; do sleep 1; done; kill $s; rm -rf $d) >/dev/null 2>&1 &"
            + " for i in {1..50}; do nc -z 127.0.0.1 $P 2>/dev/null && break; sleep 0.1; done;"
            + " stty raw -echo; nc 127.0.0.1 $P; stty sane; kill $s; rm -rf $d; exit"
    }
}
