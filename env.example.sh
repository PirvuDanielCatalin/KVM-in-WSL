export GITLAB_URL="https://gitlab.example.com"
export GITLAB_TOKEN="glrt-123456789"

# Optional: tags assigned to the runner. Defaults to the two project tags.
export GITLAB_TAGS="confluence-export,confluence-export-ui"

# Optional: API token with permission to manage runners. When set, the script
# assigns GITLAB_TAGS through the GitLab API after registration.
# export GITLAB_API_TOKEN=""
