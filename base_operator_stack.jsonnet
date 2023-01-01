local k = import 'ksonnet/ksonnet.beta.4/k.libsonnet';
local utils = import 'utils.libsonnet';
local vars = import 'vars.jsonnet';

{
  _config+:: {
    namespace: vars._config.namespace,

    urls+:: {
      domains: [vars.suffixDomain] + vars.additionalDomains,
      prom_ingress: ['prometheus.' + domain for domain in $._config.urls.domains],
      alert_ingress: ['alertmanager.' + domain for domain in $._config.urls.domains],
      grafana_ingress: ['grafana.' + domain for domain in $._config.urls.domains],
      grafana_ingress_external: 'grafana.' + vars.suffixDomain,
    },

    prometheus+:: {
      names: 'k8s',
      replicas: 1,
      namespaces: ['default', 'kube-system', 'monitoring'],
    },

    alertmanager+:: {
      replicas: 1,
    },

    kubeStateMetrics+:: {
      collectors: '',  // empty string gets a default set
      scrapeInterval: '30s',
      scrapeTimeout: '30s',

      baseCPU: '100m',
      baseMemory: '150Mi',
      cpuPerNode: '2m',
      memoryPerNode: '30Mi',
    },

    // Add custom Grafana dashboards
    grafanaDashboards+:: {
      'kubernetes-cluster-dashboard.json': (import 'grafana-dashboards/kubernetes-cluster-dashboard.json'),
      'prometheus-dashboard.json': (import 'grafana-dashboards/prometheus-dashboard.json'),
      'coredns-dashboard.json': (import 'grafana-dashboards/coredns-dashboard.json'),
    },

    grafana+:: {
      config: {
        sections: {
          session: { provider: 'memory' },
          'auth.basic': { enabled: false },
          'auth.anonymous': { enabled: false },
          smtp: {
            enabled: true,
            host: 'smtp-server.monitoring.svc:25',
            user: '',
            password: '',
            from_address: vars.grafana.from_address,
            from_name: 'Grafana Alert',
            skip_verify: true,
          },
        },
      },
      plugins: vars.grafana.plugins,
      env: vars.grafana.env
    },
  },
  //---------------------------------------
  // End of _config
  //---------------------------------------

  alertmanager+:: {
    service+: if vars.alertmanager.overrideTargetPort then {
      spec+: {
        ports:
          std.map(
            function(p)
              if p.name == 'web' then
                {
                  name: 'web',
                  port: 9093,
                  targetPort: vars.alertmanager.targetPort
                }
              else p,
            super.ports
          ),
      },
    } else {},
  },

  prometheus+:: {
    // Add option (from vars.yaml) to enable persistence
    local pvc = k.core.v1.persistentVolumeClaim,
    prometheus+: {
      spec+: {
               // Here one can use parameters from https://coreos.com/operators/prometheus/docs/latest/api.html#prometheusspec
               replicas: $._config.prometheus.replicas,
               retention: vars.prometheus.retention,
               scrapeInterval: vars.prometheus.scrapeInterval,
               scrapeTimeout: vars.prometheus.scrapeTimeout,
               externalUrl: 'http://' + $._config.urls.prom_ingress[0],
             }
             + (if vars.enablePersistence.prometheus then {
                  storage: {
                    volumeClaimTemplate:
                      pvc.new() +
                      pvc.mixin.spec.withAccessModes('ReadWriteOnce') +
                      pvc.mixin.spec.resources.withRequests({ storage: vars.enablePersistence.prometheusSizePV }) +
                      (if vars.enablePersistence.prometheusPV != null then pvc.mixin.spec.withVolumeName(vars.enablePersistence.prometheusPV)) +
                      (if vars.enablePersistence.storageClass != null then pvc.mixin.spec.withStorageClassName(vars.enablePersistence.storageClass)),
                  },
                } else {}),
    },
    service+: if vars.prometheus.overrideTargetPort then {
      spec+: {
        ports:
          std.map(
            function(p)
              if p.name == 'web' then
                {
                  name: 'web',
                  port: 9090,
                  targetPort: vars.prometheus.targetPort
                }
              else p,
            super.ports
          ),
      },
    } else {},
  },

  // Override service for Grafana if targetPort provided
  grafana+:: {
    service+: if vars.grafana.overrideTargetPort then {
      spec+: {
        ports:
          std.map(
            function(p)
              if p.name == 'http' then
                {
                  name: 'http',
                  port: 3000,
                  targetPort: vars.grafana.targetPort
                }
              else p,
            super.ports
          ),
      },
    } else {},
    deployment+: if vars.enablePersistence.grafana then {
      spec+: {
        template+: {
          spec+: {
            securityContext: {
              runAsUser: 472,
              fsGroup: 472,
              runAsNonRoot: true,
            },
            volumes:
              std.map(
                function(v)
                  if v.name == 'grafana-storage' then
                    {
                      name: 'grafana-storage',
                      persistentVolumeClaim: {
                        claimName: 'grafana-storage',
                      },
                    }
                  else v,
                super.volumes
              ),
          },
        },
      },
    } else {},
    [if vars.enablePersistence.grafana then 'storage' else null]:
      (local pvc = k.core.v1.persistentVolumeClaim;
      pvc.new() +
      pvc.mixin.metadata.withNamespace($._config.namespace) +
      pvc.mixin.metadata.withName('grafana-storage') +
      pvc.mixin.spec.withAccessModes('ReadWriteOnce') +
      pvc.mixin.spec.resources.withRequests({ storage: vars.enablePersistence.grafanaSizePV }) +
      (if vars.enablePersistence.grafanaPV != null then pvc.mixin.spec.withVolumeName(vars.enablePersistence.grafanaPV)) +
      (if vars.enablePersistence.storageClass != null then pvc.mixin.spec.withStorageClassName(vars.enablePersistence.storageClass)))
  },

  grafanaDashboards+:: $._config.grafanaDashboards,

  // Create ingress objects per application
  ingress+:: {
    alertmanager:
      local I = utils.newIngressRoute('alertmanager-main', $._config.namespace, $._config.urls.alert_ingress, '/', 'alertmanager-main', 9093);
      if vars.TLSingress then
        if vars.UseCertSecret then
          utils.addIngressRouteTLS(I, vars.CertSecret)
        else if vars.UseProvidedCerts then
          utils.addIngressTLS(I, $._config.urls.alert_ingress, 'ingress-secret')
        else
          utils.addIngressTLS(I, $._config.urls.alert_ingress)
      else
        I,

    grafana:
      local I = utils.newIngressRoute('grafana', $._config.namespace, $._config.urls.grafana_ingress, '/', 'grafana', 3000);
      if vars.TLSingress then
        if vars.UseCertSecret then
          utils.addIngressRouteTLS(I, vars.CertSecret)
        else if vars.UseProvidedCerts then
          utils.addIngressTLS(I, $._config.urls.grafana_ingress, 'ingress-secret')
        else
          utils.addIngressTLS(I, $._config.urls.grafana_ingress)
      else
        I,

    prometheus:
      local I = utils.newIngressRoute('prometheus-k8s', $._config.namespace, $._config.urls.prom_ingress, '/', 'prometheus-k8s', 9090);
      if vars.TLSingress then
        if vars.UseCertSecret then
          utils.addIngressRouteTLS(I, vars.CertSecret)
        else if vars.UseProvidedCerts then
          utils.addIngressTLS(I, $._config.urls.prom_ingress, 'ingress-secret')
        else
          utils.addIngressTLS(I, $._config.urls.prom_ingress)
      else
        I,

    // // Example external ingress with authentication
    // 'grafana-external':
    //     ingress.new() +
    //     ingress.mixin.metadata.withName('grafana-external') +
    //     ingress.mixin.metadata.withNamespace($._config.namespace) +
    //     ingress.mixin.metadata.withLabels({'traffic-type': 'external'}) +
    //     ingress.mixin.metadata.withAnnotations({
    //       'ingress.kubernetes.io/auth-type': 'basic',
    //       'ingress.kubernetes.io/auth-secret': 'basic-auth',
    //     }) +
    //     ingress.mixin.spec.withRules(
    //         ingressRule.new() +
    //         ingressRule.withHost($._config.urls.grafana_ingress_external) +
    //         ingressRule.mixin.http.withPaths(
    //             httpIngressPath.new() +
    //             httpIngressPath.withPath('/') +
    //             httpIngressPath.mixin.backend.withServiceName('grafana') +
    //             httpIngressPath.mixin.backend.withServicePort('http')
    //         ),
    //     ),
    // 'basic-auth-secret':
    //     // First generate the auth secret with gen_auth.sh script
    //     secret.new('basic-auth', { auth: std.base64(importstr 'auth') }) +
    //     secret.mixin.metadata.withNamespace($._config.namespace),
  } + if vars.UseProvidedCerts then {
    secret:
      utils.newTLSSecret('ingress-secret', $._config.namespace, vars.TLSCertificate, vars.TLSKey),
  } else {},
}
