# Observability 

This Application comprised a suite of Open Telemetry Collector.

- A Node collector on each node
- A Cluster collector
- A Gateway collector

See the [source repository](https://github.com/pc-dae/observability) for details

Deployment requires an `apps.yaml` entry containing

```yaml
apps:
  - name: otel
    namespace: otel
    secrets:
      newrelic-key:
        licenseKey: ${NEWRELIC_LICENSE_KEY}
      splunk-hec-token:
        hecToken: ${SPLUNK_HEC_TOKEN}
```

The `splunk-hec-token` secret is required but Splunk exporter can be disabled so it is not used.

Also a GitHub token is required to access the source repository. Add to your `resources/secrets` folder:

`apps/otel/observability-git-token`

containing:

```json
{
    "password": "${GITHUB_TOKEN_OBSERV_READ}",
    "username": "git"
}
```

The token can be obtained from [Paul Carlton](mailto:paul.carlton@dae.mn)
