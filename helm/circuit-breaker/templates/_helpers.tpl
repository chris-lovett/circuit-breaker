{{/*
Expand the name of the chart.
*/}}
{{- define "circuit-breaker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this
(by the DNS naming spec).  If the release name contains the chart name it will
be used as-is.
*/}}
{{- define "circuit-breaker.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label value (name-version).
*/}}
{{- define "circuit-breaker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "circuit-breaker.labels" -}}
helm.sh/chart: {{ include "circuit-breaker.chart" . }}
{{ include "circuit-breaker.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels (used in matchLabels / selector).
*/}}
{{- define "circuit-breaker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "circuit-breaker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "circuit-breaker.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "circuit-breaker.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Target namespace – falls back to the release namespace when not explicitly set.
*/}}
{{- define "circuit-breaker.namespace" -}}
{{- default .Release.Namespace .Values.namespace }}
{{- end }}

{{/*
Standard Consul connect-inject annotations shared by all application Pods.
*/}}
{{- define "circuit-breaker.consulAnnotations" -}}
consul.hashicorp.com/connect-inject: "true"
{{- with .Values.consul.namespace }}
consul.hashicorp.com/namespace: {{ . | quote }}
{{- end }}
{{- with .Values.consul.podAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}
