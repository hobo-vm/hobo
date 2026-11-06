# Restores the network after a resume. The virtio NIC stops working when VZ restores a saved Windows
# VM; nothing the host does brings it back, but restarting the adapter does, within a second or so
# (spikes/windows-qemu/README.md, finding 21). It also mends any other loss of the gateway. A gateway
# that has never answered may just not answer pings (a host firewall's stealth mode), so it takes one
# that did and stopped; memory comes back with a resume, so this remembers across one.
$hasAnswered = $false
$failures = 0
while ($true) {
    Start-Sleep -Seconds 1
    $gateway = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.NetworkInterfaceType -eq 'Ethernet' } |
        ForEach-Object { $_.GetIPProperties().GatewayAddresses } |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } |
        Select-Object -First 1
    if (-not $gateway) { continue }
    try {
        $answered = (New-Object Net.NetworkInformation.Ping).Send($gateway.Address, 1000).Status -eq 'Success'
    } catch {
        $answered = $false
    }
    if ($answered) {
        $hasAnswered = $true
        $failures = 0
    } elseif ($hasAnswered -and ++$failures -ge 2) {
        Get-NetAdapter -Physical | Restart-NetAdapter -Confirm:$false
        $failures = 0
        Start-Sleep -Seconds 10
    }
}
