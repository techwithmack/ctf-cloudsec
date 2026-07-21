# Wraps the official Forgejo image with a bootstrap script that, on first boot,
# idempotently provisions the org/repo/player/branch-protection/workflow needed for
# Challenge 2 and hands off a CI runner registration token via SSM Parameter Store.
FROM codeberg.org/forgejo/forgejo:15

RUN apk add --no-cache aws-cli jq

COPY bootstrap.sh /bootstrap.sh
COPY deploy-workflow.yml /deploy-workflow.yml
RUN chmod +x /bootstrap.sh

ENTRYPOINT ["/bootstrap.sh"]
