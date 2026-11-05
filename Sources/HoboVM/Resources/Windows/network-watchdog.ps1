# Restores the network after a resume. The virtio NIC stops working when VZ restores a saved Windows
# VM; nothing the host does brings it back, but restarting the adapter does, within a second or so
# (spikes/windows-qemu/README.md, finding 21). It also mends any other loss of the gateway.
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
        $failures = 0
    } elseif (++$failures -ge 2) {
        Get-NetAdapter -Physical | Restart-NetAdapter -Confirm:$false
        $failures = 0
        Start-Sleep -Seconds 10
    }
}
