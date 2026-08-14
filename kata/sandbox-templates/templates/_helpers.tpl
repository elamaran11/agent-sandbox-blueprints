{{/*
Helpers taken from the OAP agent-sandbox chart so the two templates beside them
stay byte-identical to the working version. The kataUserData helper is
deliberately NOT copied: it builds nodeadm userData for the Crossplane managed
node group, which this blueprint replaces with Karpenter nested-virt NodePools.
*/}}

{{- define "agent-sandbox.labels" -}}
app.kubernetes.io/name: agent-sandbox
app.kubernetes.io/part-of: open-agent-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "agent-sandbox.selectorLabels" -}}
app.kubernetes.io/name: agent-sandbox
{{- end -}}

{{- define "agent-sandbox.namespace" -}}
{{- default "agent-sandbox-system" .Values.namespace -}}
{{- end -}}
