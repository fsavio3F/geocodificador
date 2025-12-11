# WSL2 Troubleshooting Guide

## Clock Synchronization Issues in Elasticsearch

### Problem

When running the geocodificador on WSL2 (Windows Subsystem for Linux 2), you may encounter frequent warnings in Elasticsearch logs like:

```json
{
  "@timestamp":"2025-12-11T18:01:57.366Z",
  "log.level": "WARN",
  "message":"absolute clock went backwards by [459ms/459ms] while timer thread was sleeping",
  ...
}
```

### Root Cause

WSL2 uses a virtual machine that can experience clock drift issues, especially when:
- The Windows host goes to sleep/hibernates
- There's high CPU load
- Time synchronization between WSL2 and Windows gets out of sync

### Solution 1: Configuration (Recommended)

The geocodificador includes an Elasticsearch configuration file (`elasticsearch/elasticsearch.yml`) that suppresses these warnings by setting the logging level for the ThreadPool to ERROR:

```yaml
# Logging configuration to suppress timer warnings
logger.org.elasticsearch.threadpool: ERROR
```

This is already configured in `docker-compose.yml` and will be automatically used when you start the services.

### Solution 2: Manual WSL2 Clock Sync

If you experience issues beyond the warnings, you can manually synchronize the WSL2 clock:

```bash
# In your WSL2 terminal
sudo hwclock -s
```

Or restart the WSL2 time synchronization service:

```bash
sudo service ntp restart
```

### Solution 3: Windows Time Service

Ensure Windows time service is running properly:

1. Open PowerShell as Administrator
2. Run:
```powershell
Get-Service W32Time | Start-Service
w32tm /resync
```

### Solution 4: WSL2 Configuration

Create or edit `.wslconfig` in your Windows user directory (`C:\Users\<YourUsername>\.wslconfig`):

```ini
[wsl2]
kernelCommandLine = clocksource=tsc
```

Then restart WSL2:
```powershell
# In PowerShell (as Administrator)
wsl --shutdown
```

### Solution 5: Automatic Time Sync Script

Create a cron job in WSL2 to periodically sync time:

```bash
# Add to crontab
(crontab -l 2>/dev/null; echo "*/5 * * * * sudo hwclock -s") | crontab -

# Or create a systemd service (if systemd is enabled in WSL2)
sudo systemctl enable systemd-timesyncd
sudo systemctl start systemd-timesyncd
```

### Verification

After applying any of the solutions above, verify that the warnings are reduced or eliminated:

```bash
# Check Elasticsearch logs
docker compose logs -f elasticsearch

# You should see fewer or no "clock went backwards" warnings
```

### Impact Assessment

**Good News**: These clock warnings are generally **harmless** for the geocodificador system because:

1. ✅ They don't affect data integrity
2. ✅ They don't impact API performance
3. ✅ They don't cause data loss
4. ✅ They don't affect geocoding accuracy
5. ✅ The system continues to function normally

**What They Mean**: The warnings indicate that Elasticsearch's internal timer detected a small time discrepancy, but Elasticsearch handles this gracefully and continues operating normally.

### When to Worry

You should only be concerned if you see:
- ❌ Actual Elasticsearch errors (not just warnings)
- ❌ Failed requests to the API
- ❌ Data indexing failures
- ❌ Very large time jumps (> 10 seconds)

### Additional WSL2 Best Practices

1. **Keep WSL2 Updated**:
   ```powershell
   # In PowerShell
   wsl --update
   ```

2. **Allocate Sufficient Resources**:
   Edit `.wslconfig` to ensure adequate memory:
   ```ini
   [wsl2]
   memory=4GB
   processors=2
   ```

3. **Regular Docker Maintenance**:
   ```bash
   # Clean up old containers and volumes
   docker system prune -a
   ```

## Related Issues

- [WSL2 Clock Skew Issue](https://github.com/microsoft/WSL/issues/4245)
- [Elasticsearch Timer Warnings](https://github.com/elastic/elasticsearch/issues/47438)

## Need Help?

If you continue to experience issues after trying these solutions, please open an issue on the GitHub repository with:
- Your WSL2 version (`wsl --version`)
- Docker version (`docker --version`)
- Elasticsearch logs from the time of the issue
- Steps to reproduce the problem
