# Useful Commands

## Git pull as the gitdeploy user

```bash
sudo -u gitdeploy git pull
```

Or, to specify the repo path explicitly:

```bash
sudo -u gitdeploy bash -c "cd /path/to/repo && git pull"
```
