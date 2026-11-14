import Foundation

/// Conformances that collapse the generator's fourteen identical metrics response types onto
/// ``MetricSeries``.
///
/// Every extension here is empty. The generated structs already declare `field`/`value`,
/// `timestamp`/`value`, and `labels`/`values`/`unit` with exactly the types the protocols require, so
/// the conformance is a statement that the shape matched — checked by the compiler, at no runtime
/// cost and with no mapping code to keep in sync.
///
/// One line per endpoint is the price of the spec inlining these schemas instead of naming them as
/// components. If Render ever gives them a `$ref`, this whole file becomes three lines.

// MARK: - CPU

extension Operations.GetCpu.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetCpu.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetCpu.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

extension Operations.GetCpuLimit.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetCpuLimit.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetCpuLimit.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

extension Operations.GetCpuTarget.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetCpuTarget.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetCpuTarget.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

// MARK: - Memory

extension Operations.GetMemory.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetMemory.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetMemory.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

extension Operations.GetMemoryLimit.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetMemoryLimit.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetMemoryLimit.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

extension Operations.GetMemoryTarget.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetMemoryTarget.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetMemoryTarget.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

// MARK: - HTTP

extension Operations.GetHttpRequests.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetHttpRequests.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetHttpRequests.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

extension Operations.GetHttpLatency.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetHttpLatency.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetHttpLatency.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

// MARK: - Capacity and traffic

extension Operations.GetBandwidth.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetBandwidth.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetBandwidth.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

extension Operations.GetInstanceCount.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetInstanceCount.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetInstanceCount.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

extension Operations.GetActiveConnections.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetActiveConnections.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetActiveConnections.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

// MARK: - Disk

extension Operations.GetDiskUsage.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetDiskUsage.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetDiskUsage.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

extension Operations.GetDiskCapacity.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetDiskCapacity.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetDiskCapacity.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

// MARK: - Traffic sources and replication

extension Operations.GetBandwidthSources.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetBandwidthSources.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetBandwidthSources.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}

extension Operations.GetReplicationLag.Output.Ok.Body.JsonPayloadPayload.LabelsPayloadPayload: MetricSeriesLabelPayload {}
extension Operations.GetReplicationLag.Output.Ok.Body.JsonPayloadPayload.ValuesPayloadPayload: MetricSeriesPointPayload {}
extension Operations.GetReplicationLag.Output.Ok.Body.JsonPayloadPayload: MetricSeriesPayload {}
