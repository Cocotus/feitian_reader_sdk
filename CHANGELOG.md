## 0.0.1

* Initial release: Flutter plugin for FEITIAN cardreader over bluetooth using PCSC interface
* Basic APDU command support (sendApduCommand method)
* Card connection management (connectReader, disconnectReader)
* Card power control (powerOnCard, powerOffCard)
* UID reading functionality (readUID)
* iOS platform support (12.0+)
* Method channel callbacks for logs, data, and APDU responses
* Example app demonstrating all plugin features
* Based on FEITIAN SDK 3.5.71 demo project (OperationViewController)
