{{- define "kata-sandbox.namespace" -}}
{{ .Values.namespace | default "agent-sandbox-system" }}
{{- end -}}

{{- define "kata-sandbox.labels" -}}
app.kubernetes.io/name: kata-sandbox-templates
app.kubernetes.io/managed-by: {{ .Release.Service }}
agent-sandbox.io/substrate: kata
{{- end -}}

{{- define "kata-sandbox.selectorLabels" -}}
app.kubernetes.io/name: kata-sandbox-templates
{{- end -}}

{{- /*
Fail the render rather than deploying a template that can never pull. `task kata`
substitutes coderImage from terraform; a bare `helm template` for linting still
works because lint passes the placeholder through unchanged — this only fires when
someone blanks it out entirely.
*/ -}}
{{- define "kata-sandbox.coderImage" -}}
{{- $img := .Values.coderImage | default "" -}}
{{- if not $img -}}
{{- fail "coderImage is empty — set it, or run `task kata` which reads it from the terraform coder_ecr_urls output" -}}
{{- end -}}
{{ $img }}:{{ .Values.imageTag | default "latest" }}
{{- end -}}
