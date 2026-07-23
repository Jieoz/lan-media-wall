/// Admission result for a device-confirmed runtime-mode reply.
enum RuntimeModeReplyAdmission {
  accept,
  superseded,
  staleOrDeviceMismatch,
}

/// Tracks request/device ownership and the newest runtime-mode request per device.
///
/// This class deliberately owns no timers or completers. [WallState] owns those
/// lifecycle concerns and calls [cancel] on send failure/timeout. Keeping the
/// ordering reducer pure makes replay, cross-device and out-of-order behavior
/// deterministic and directly unit-testable.
class RuntimeModeRequestTracker {
  final Map<String, String> _deviceByRequest = {};
  final Map<String, String> _latestRequestByDevice = {};

  void register({required String requestId, required String deviceId}) {
    _deviceByRequest[requestId] = deviceId;
    _latestRequestByDevice[deviceId] = requestId;
  }

  RuntimeModeReplyAdmission settle({
    required String requestId,
    required String actualDeviceId,
  }) {
    final expectedDeviceId = _deviceByRequest.remove(requestId);
    if (expectedDeviceId == null || expectedDeviceId != actualDeviceId) {
      if (expectedDeviceId != null &&
          _latestRequestByDevice[expectedDeviceId] == requestId) {
        _latestRequestByDevice.remove(expectedDeviceId);
      }
      return RuntimeModeReplyAdmission.staleOrDeviceMismatch;
    }
    if (_latestRequestByDevice[actualDeviceId] != requestId) {
      return RuntimeModeReplyAdmission.superseded;
    }
    _latestRequestByDevice.remove(actualDeviceId);
    return RuntimeModeReplyAdmission.accept;
  }

  /// Removes a timed-out or failed request. A newer request for the same device
  /// is retained because its request id no longer matches [requestId].
  void cancel(String requestId) {
    final deviceId = _deviceByRequest.remove(requestId);
    if (deviceId != null && _latestRequestByDevice[deviceId] == requestId) {
      _latestRequestByDevice.remove(deviceId);
    }
  }

  bool contains(String requestId) => _deviceByRequest.containsKey(requestId);
  String? latestForDevice(String deviceId) => _latestRequestByDevice[deviceId];
}
