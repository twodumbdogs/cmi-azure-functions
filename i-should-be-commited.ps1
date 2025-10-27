# Get current date and time
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Get list of changed files
$changes = git status --short

# Build commit message
$commitMessage = "$timestamp - gabe committed changes`n`nChanged files:`n$changes"

# Stage all changes
git add .

# Commit with message
git commit -m "$commitMessage"

# Push to origin main
git push origin main