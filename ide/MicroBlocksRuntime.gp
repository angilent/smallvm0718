// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Copyright 2019 John Maloney, Bernat Romagosa, and Jens Mönig

// SmallCompiler.gp - A blocks compiler for SmallVM
// John Maloney, April, 2017

to smallRuntime aScripter {
	if (isNil (global 'smallRuntime')) {
		setGlobal 'smallRuntime' (initialize (new 'SmallRuntime') aScripter)
	}
	return (global 'smallRuntime')
}

defineClass SmallRuntime scripter chunkIDs chunkRunning msgDict portName port lastScanMSecs pingSentMSecs lastPingRecvMSecs recvBuf oldVarNames vmVersion boardType lastBoardDrives loggedData loggedDataNext loggedDataCount vmInstallMSecs disconnected

method scripter SmallRuntime { return scripter }

method initialize SmallRuntime aScripter {
	scripter = aScripter
	chunkIDs = (dictionary)
	clearLoggedData this
	return this
}

method evalOnBoard SmallRuntime aBlock showBytes {
	if (isNil showBytes) { showBytes = false }
	if showBytes {
		bytes = (chunkBytesFor this aBlock)
		print (join 'Bytes for chunk ' id ':') bytes
		print '----------'
		return
	}
	saveAllChunks this
	if (isNil (ownerThatIsA (morph aBlock) 'ScriptEditor')) {
		// running a block from the palette, not included in saveAllChunks
		saveChunk this aBlock
	}
	runChunk this (lookupChunkID this aBlock)
}

method chunkTypeFor SmallRuntime aBlockOrFunction {
	if (isClass aBlockOrFunction 'Function') { return 3 }

	expr = (expression aBlockOrFunction)
	op = (primName expr)
	if ('whenStarted' == op) { return 4 }
	if ('whenCondition' == op) { return 5 }
	if ('whenBroadcastReceived' == op) { return 6 }
	if ('whenButtonPressed' == op) {
		button = (first (argList expr))
		if ('A' == button) { return 7 }
		if ('B' == button) { return 8 }
		return 9 // A+B
	}
	if (isClass expr 'Command') { return 1 }
	if (isClass expr 'Reporter') { return 2 }

	error 'Unexpected argument to chunkTypeFor'
}

method chunkBytesFor SmallRuntime aBlockOrFunction {
	compiler = (initialize (new 'SmallCompiler'))
	code = (instructionsFor compiler aBlockOrFunction)
	bytes = (list)
	for item code {
		if (isClass item 'Array') {
			addBytesForInstructionTo compiler item bytes
		} (isClass item 'Integer') {
			addBytesForIntegerLiteralTo compiler item bytes
		} (isClass item 'String') {
			addBytesForStringLiteral compiler item bytes
		} else {
			error 'Instruction must be an Array or String:' item
		}
	}
	return bytes
}

method showInstructions SmallRuntime aBlock {
	// Display the instructions for the given stack.

	compiler = (initialize (new 'SmallCompiler'))
	code = (instructionsFor compiler (topBlock aBlock))
	result = (list)
	for item code {
		if (not (isClass item 'Array')) {
			addWithLineNum this result (toString item)
		} ('pushImmediate' == (first item)) {
			arg = (at item 2)
			if (1 == (arg & 1)) {
				arg = (arg >> 1) // decode integer
				if (arg >= 4194304) { arg = (arg - 8388608) }
			} (0 == arg) {
				arg = false
			} (4 == arg) {
				arg = true
			}
			addWithLineNum this result (join 'pushImmediate ' arg)
		} ('pushBigImmediate' == (first item)) {
			addWithLineNum this result 'pushBigImmediate' // don't show arg count; could be confusing
		} ('callFunction' == (first item)) {
			arg = (at item 2)
			calledChunkID = ((arg >> 8) & 255)
			argCount = (arg & 255)
			addWithLineNum this result (join 'callFunction ' calledChunkID ' ' argCount)
		} (not (isLetter (at (first item) 1))) { // operator; don't show arg count
			addWithLineNum this result (toString (first item))
		} else {
			// instruction (an array of form <cmd> <args...>)
			instr = ''
			for s item { instr = (join instr s ' ') }
			addWithLineNum this result instr item
		}
	}
	ws = (openWorkspace (global 'page') (joinStrings result (newline)))
	setTitle ws 'Instructions'
	setFont ws 'Arial' (16 * (global 'scale'))
	setExtent (morph ws) (220 * (global 'scale')) (400 * (global 'scale'))
}

method addWithLineNum SmallRuntime aList instruction items {
	currentLine = ((count aList) + 1)
	targetLine = ''
	if (and
		(notNil items)
		(isOneOf (first items)
			'pushLiteral' 'jmp' 'jmpTrue' 'jmpFalse'
			'decrementAndJmp' 'callFunction' 'forLoop')) {
		offset = (toInteger (last items))
		targetLine = (join ' (line ' (+ currentLine 1 offset) ')')
	}
	add aList (join '' currentLine ' ' instruction targetLine)
}

method showCompiledBytes SmallRuntime aBlock {
	// Display the instruction bytes for the given stack.

	bytes = (chunkBytesFor this aBlock)
	result = (list)
	for i (count bytes) {
		add result (toString (at bytes i))
		if (0 == (i % 4)) {
			add result (newline)
		} else {
			add result ' '
		}
	}
	if (and ((count result) > 0) ((newline) == (last result))) { removeLast result }
	ws = (openWorkspace (global 'page') (joinStrings result))
	setTitle ws 'Instruction Bytes'
	setFont ws 'Arial' (16 * (global 'scale'))
	setExtent (morph ws) (220 * (global 'scale')) (400 * (global 'scale'))
}

// chunk management

method syncScripts SmallRuntime {
	if (notNil port) { saveAllChunks this }
}

method lookupChunkID SmallRuntime key {
	// If the given block or function name has been assigned a chunkID, return it.
	// Otherwise, return nil.

	entry = (at chunkIDs key nil)
	if (isNil entry) { return nil }
	return (first entry)
}

method removeObsoleteChunks SmallRuntime {
	// Remove obsolete chunks. Chunks become obsolete when they are deleted or inserted into
	// a script so they are no longer a stand-alone chunk.

	for k (keys chunkIDs) {
		entry = (at chunkIDs k)
		if (isClass k 'Block') {
			owner = (owner (morph k))
			isObsolete = (or
				(isNil owner)
				(isNil (handler owner))
				(not (isAnyClass (handler owner) 'Hand' 'ScriptEditor' 'BlocksPalette')))
			if isObsolete {
				id = (first entry)
				deleteChunkForBlock this k
			}
		}
	}
}

method unusedChunkID SmallRuntime {
	// Return an unused chunkID.

	inUse = (dictionary)
	for entry (values chunkIDs) {
		add inUse (first entry) // the chunk ID is first element of entry
	}
	for i 256 {
		id = (i - 1)
		if (not (contains inUse id)) { return id }
	}
	error 'Too many code chunks (functions and scripts). Max is 256).'
}

method ensureChunkIdFor SmallRuntime aBlock {
	// Return the chunkID for the given block. Functions are handled by assignFunctionIDs.
	// If necessary, register the block in the chunkIDs dictionary.

	entry = (at chunkIDs aBlock nil)
	if (isNil entry) {
		id = (unusedChunkID this)
		entry = (array id aBlock) // block -> <id> <last expression>
		atPut chunkIDs aBlock entry
	}
	return (first entry)
}

method assignFunctionIDs SmallRuntime {
	// Ensure that there is a chunk ID for every user-defined function.
	// This must be done before generating any code to allow for recursive calls.

	for func (allFunctions (project scripter)) {
		fName = (functionName func)
		if (not (contains chunkIDs fName)) {
			atPut chunkIDs fName (array (unusedChunkID this) 'New Function!') // forces function save
		}
	}
}

method deleteChunkForBlock SmallRuntime aBlock {
	key = aBlock
	if (isPrototypeHat aBlock) {
		key = (functionName (function (editedPrototype aBlock)))
	}
	entry = (at chunkIDs key nil)
	if (and (notNil entry) (notNil port)) {
		chunkID = (first entry)
		sendMsgSync this 'deleteChunkMsg' chunkID
		remove chunkIDs key
	}
}

method stopAndSyncScripts SmallRuntime {
	// Stop everyting and sync scripts with the board.

	clearBoardIfConnected this false
	oldVarNames = nil // force var names to be updated
	saveAllChunks this
}

method softReset SmallRuntime {
	// Stop everyting, clear memory, and reset the I/O pins.

	sendMsg this 'systemResetMsg' // send the reset message
}

method selectPort SmallRuntime {
	if (isNil disconnected) { disconnected = false }

	portList = (portList this)
	menu = (menu 'Connect' (action 'setPort' this) true)
	if (or disconnected (devMode)) {
		for s portList { addItem menu s }
	}
	if (devMode) {
		addLine menu
		addItem menu 'other...'
	}
	if (or (notNil port) (devMode)) {
		addLine menu
		addItem menu 'disconnect'
	}
	popUpAtHand menu (global 'page')
}

method portList SmallRuntime {
	portList = (list)
	if ('Win' == (platform)) {
		portList = (toList (listSerialPorts))
		remove portList 'COM1'
	} ('Browser' == (platform)) {
		listSerialPorts // first call triggers callback
		waitMSecs 50
		portList = (list)
		for portName (listSerialPorts) {
			if (not (beginsWith portName '/dev/tty.')) {
				add portList portName
			}
		}
	} else {
		for fn (listFiles '/dev') {
			if (or	(notNil (nextMatchIn 'usb' (toLowerCase fn) )) // MacOS
					(notNil (nextMatchIn 'acm' (toLowerCase fn) ))) { // Linux
				add portList (join '/dev/' fn)
			}
		}
		// Mac OS lists a port as both cu.<name> and tty.<name>
		for s (copy portList) {
			if (beginsWith s '/dev/tty.') {
				if (contains portList (join '/dev/cu.' (substring s 10))) {
					remove portList s
				}
			}
		}
	}
	return portList
}

method setPort SmallRuntime newPortName {
	if ('disconnect' == newPortName) {
		if (notNil port) {
			stopAndSyncScripts this
			sendStartAll this
		}
		closePort this
		disconnected = true
		updateIndicator (findMicroBlocksEditor)
		return
	}
	if ('other...' == newPortName) {
		newPortName = (prompt (global 'page') 'Port name?' (localized 'none'))
		if ('' == newPortName) { return }
	}
	closePort this
	disconnected = false

	// the prompt answer 'none' is entered by the user in the current language
	if (or (isNil newPortName) (newPortName == (localized 'none'))) {
		portName = nil
	} else {
		portName = newPortName
		reconnectToCurrentPort this
	}
	updateIndicator (findMicroBlocksEditor)
}

method closePort SmallRuntime {
	// Close the serial port and clear info about the currently connected board.

	if (notNil port) { closeSerialPort port }
	port = nil
	vmVersion = nil
	boardType = nil
}

method boardRespondsToPing SmallRuntime {
	// Return true if the board responds to a ping request.

	// A Chromebook can't poll; it must return control to the DOM to receive serial data.
	if ('Browser' == (platform)) { return true }

	shortTimeout = 50
	if (isNil port) { return false }
	lastPingRecvMSecs = 0
	sendMsg this 'pingMsg'
	pingSentMSecs = (msecsSinceStart)
	while (0 == lastPingRecvMSecs) {
		processMessages this
		now = (msecsSinceStart)
		if (now < pingSentMSecs) { pingSentMSecs = 0 } // clock wrap
		if ((now - pingSentMSecs) > shortTimeout) { return false } // timed out
	}
	return true
}

method reconnectToCurrentPort SmallRuntime {
	// Close and reopen the current port and wait for a ping. Return true if successful.

	if (isNil portName) { return false }
	if (not (contains (portList this) portName)) { return false }

	closePort this // close the port
	ensurePortOpen this // attempt to reopen the port
	if (and (notNil port) (boardRespondsToPing this)) {
		// succeeded! request the VM version
		print 'Connected!'
		lastPingRecvMSecs = (msecsSinceStart)
		vmVersion = nil
		sendMsg this 'getVersionMsg'
		stopAndSyncScripts this
		return true
	}

	// board not responding; look for board on another port
	if (notNil port) { closePort this }
	return false
}

method tryToConnect SmallRuntime {
	// Called when there is no connection or the board does not respond.
	// First, try to close and reopen the existing port, if there is one.
	// If that fails, look for a port that responds to a 'ping'.

	if (reconnectToCurrentPort this) { return 'connected' }

	if (isNil lastScanMSecs) { lastScanMSecs = 0 }
	msecsSinceLastScan = ((msecsSinceStart) - lastScanMSecs)
	if (and (msecsSinceLastScan > 0) (msecsSinceLastScan < 1000)) { return }
	lastScanMSecs = (msecsSinceStart)

	print 'Trying to connect...'
	for p (portList this) {
		portName = p
		if (reconnectToCurrentPort this) { return 'connected' }
	}
	portName = nil

	// no port responded ping requests; try to install VM
	tryToInstallVM this
	return 'not connected'
}

method tryToInstallVM SmallRuntime {
	// Invite the user to install VM if we see a new board drive and are not able to connect to
	// it withing a few seconds. Remember the last set of boardDrives so we don't keep asking.
	// Details: On Mac OS (at least), 3-4 seconds elapse between when the board drive appears
	// and when the USB-serial port appears. Thus, the IDE waits a bit to see if it can connect
	// to the board before prompting the user to install the VM to avoid spurious prompts.

	if (and (notNil vmInstallMSecs) ((msecsSinceStart) > vmInstallMSecs)) {
		vmInstallMSecs = nil
		if (and (notNil port) (isOpenSerialPort port)) { return }
		ok = (confirm (global 'page') nil (join
			(localized 'The board is not responding.') (newline)
			(localized 'Try to Install MicroBlocks on the board?')))
		if ok { installVM this }
		return
	}

	boardDrives = (collectBoardDrives this)
	if (lastBoardDrives == boardDrives) { return }
	lastBoardDrives = boardDrives
	if (isEmpty boardDrives) {
		vmInstallMSecs = nil
	} else {
		vmInstallMSecs = ((msecsSinceStart) + 5000) // prompt to install VM in a few seconds
	}
}

method updateConnection SmallRuntime {
	pingSendInterval = 2000 // msecs between pings
	pingTimeout = 3000
	if (isNil pingSentMSecs) { pingSentMSecs = 0 }
	if (isNil lastPingRecvMSecs) { lastPingRecvMSecs = 0 }
	if (isNil disconnected) { disconnected = false }

	if disconnected { return 'not connected' }

	// if port is not open, try to reconnect or find a different board
	if (or (isNil port) (not (isOpenSerialPort port))) {
		closePort this
		return (tryToConnect this)
	}

	// if the port is open and it is time, send a ping
	now = (msecsSinceStart)
	if ((now - pingSentMSecs) > pingSendInterval) {
		if ((now - pingSentMSecs) > 5000) {
			// it's been a long time since we sent a ping; laptop may have been asleep
			// set lastPingRecvMSecs to N seconds into future to suppress warnings
			lastPingRecvMSecs = now
		}
		sendMsg this 'pingMsg'
		pingSentMSecs = now
		return 'connected'
	}

	msecsSinceLastPing = (now - lastPingRecvMSecs)
	if (msecsSinceLastPing < pingTimeout) {
		// got a ping recently: we're connected
		return 'connected'
	} else {
		// ping timout: close port to force reconnection
		closePort this
		return 'not connected'
	}
}

method ideVersion SmallRuntime { return '0.2.1' }
method latestVmVersion SmallRuntime { return 63 }

method showAboutBox SmallRuntime {
	vmVersionReport = ''
	if (notNil vmVersion) {
		vmVersionReport = (join '(Firmware v' vmVersion ')' (newline))
	}
	inform (global 'page') (join
		'MicroBlocks v' (ideVersion this) (newline)
		vmVersionReport
		(localized 'by') (newline)
		'John Maloney, Bernat Romagosa, and Jens Mönig' (newline)
		'Created with GP (gpblocks.org)' (newline)
		(localized 'More info at http://microblocks.fun'))
}

method getVersion SmallRuntime {
	sendMsg this 'getVersionMsg'
}

method extractVersionNumber SmallRuntime versionString {
	// Return the version number from the versionString.
	// Version string format: vNNN, where NNN is one or more decimal digits,
	// followed by non-digits characters that are ignored. Ex: 'v052a micro:bit'

	words = (words (substring versionString 2))
	if (isEmpty words) { return -1 }
	result = 0
	for ch (letters (first words)) {
		if (not (isDigit ch)) { return result }
		digit = ((byteAt ch 1) - (byteAt '0' 1))
		result = ((10 * result) + digit)
	}
	return result
}

method extractBoardType SmallRuntime versionString {
	// Return the board type from the versionString.
	// Version string format: vNNN [boardType]

	words = (words (substring versionString 2))
	if (isEmpty words) { return -1 }
	return (joinStrings (copyWithout words (at words 1)) ' ')
}

method versionReceived SmallRuntime versionString {
	if (isNil vmVersion) { // first time: record and check the version number
		vmVersion = (extractVersionNumber this versionString)
		boardType = (extractBoardType this versionString)
		checkVmVersion this
		installBoardSpecificBlocks this
	} else { // not first time: show the version number
		inform (global 'page') (join 'MicroBlocks Virtual Machine' (newline) versionString)
	}
}

method checkVmVersion SmallRuntime {
	if ((latestVmVersion this) > vmVersion) {
		ok = (confirm (global 'page') nil (join
			(localized 'The MicroBlocks in your board is not current ')
			'(v' vmVersion ' vs. v' (latestVmVersion this) ').' (newline)
			(localized 'Try to update MicroBlocks on the board?')))
		if ok {
			installVM this
		}
	}
}

method installBoardSpecificBlocks SmallRuntime {
	// installs default blocks libraries for each type of board.

	if ('Citilab ED1' == boardType) {
		importLibraryFromFile scripter '//Libraries/Citilab ED1/ED1 Buttons.ubl'
		importLibraryFromFile scripter '//Libraries/Tone.ubl'
		importLibraryFromFile scripter '//Libraries/Basic Sensors.ubl'
		importLibraryFromFile scripter '//Libraries/LED Display.ubl'
		importLibraryFromFile scripter '//Libraries/TFT.ubl'
		importLibraryFromFile scripter '//Libraries/Web of Things.ubl'
	} ('micro:bit' == boardType) {
		importLibraryFromFile scripter '//Libraries/Basic Sensors.ubl'
		importLibraryFromFile scripter '//Libraries/LED Display.ubl'
	} ('Calliope' == boardType) {
		importLibraryFromFile scripter '//Libraries/Calliope.ubl'
		importLibraryFromFile scripter '//Libraries/Basic Sensors.ubl'
		importLibraryFromFile scripter '//Libraries/LED Display.ubl'
	} ('CircuitPlayground' == boardType) {
		importLibraryFromFile scripter '//Libraries/Circuit Playground.ubl'
		importLibraryFromFile scripter '//Libraries/Basic Sensors.ubl'
		importLibraryFromFile scripter '//Libraries/NeoPixel.ubl'
		importLibraryFromFile scripter '//Libraries/Tone.ubl'
	} ('ESP8266' == boardType) {
		importLibraryFromFile scripter '//Libraries/Web of Things.ubl'
	} ('ESP32' == boardType) {
		importLibraryFromFile scripter '//Libraries/Web of Things.ubl'
	}
}

method clearBoardIfConnected SmallRuntime doReset {
	if (notNil port) {
		sendStopAll this
		if doReset { softReset this }
		clearVariableNames this
		sendMsgSync this 'deleteAllCodeMsg' // delete all code from board
		waitMSecs 300 // this can be slow; give the board a chance to process it
	}
	allStopped this
	chunkIDs = (dictionary)
}

method sendStopAll SmallRuntime {
	sendMsg this 'stopAllMsg'
	allStopped this
}

method sendStartAll SmallRuntime {
	oldVarNames = nil // force var names to be updated
	saveAllChunks this
	sendMsg this 'startAllMsg'
}

method saveAllChunks SmallRuntime {
	// Save the code for all scripts and user-defined functions.

	if (isNil port) { return }
	saveVariableNames this
	assignFunctionIDs this
	removeObsoleteChunks this
	for aFunction (allFunctions (project scripter)) {
		saveChunk this aFunction
	}
	for aBlock (sortedScripts (scriptEditor scripter)) {
		if (not (isPrototypeHat aBlock)) { // skip function def hat; functions get saved above
			saveChunk this aBlock
		}
	}
}

method saveChunk SmallRuntime aBlockOrFunction {
	// Save the script starting with the given block or function as an executable code "chunk".
	// Also save the source code (in GP format) and the script position.

	if (isClass aBlockOrFunction 'Function') {
		chunkID = (lookupChunkID this (functionName aBlockOrFunction))
		entry = (at chunkIDs (functionName aBlockOrFunction))
		newCode = (cmdList aBlockOrFunction)
	} else {
		chunkID = (ensureChunkIdFor this aBlockOrFunction)
		entry = (at chunkIDs aBlockOrFunction)
		newCode = (expression aBlockOrFunction)
	}

	if (newCode == (at entry 2)) { return } // code hasn't changed
	if (notNil newCode) { newCode = (copy newCode) }
	atPut entry 2 newCode // remember the code we're about to save

	// save the binary code for the chunk
	chunkType = (chunkTypeFor this aBlockOrFunction)
	data = (list chunkType)
	addAll data (chunkBytesFor this aBlockOrFunction)
	if ((count data) > 1000) {
		if (isClass aBlockOrFunction 'Function') {
			inform (global 'page') (join
				(localized 'Function "') (functionName aBlockOrFunction)
				(localized '" is too large to send to board.'))
		} else {
			showHint (morph aBlockOrFunction) (localized 'Script is too large to send to board.')
		}
	}
	sendMsgSync this 'chunkCodeMsg' chunkID data

	// restart the chunk if it is a Block and is running
	if (and (isClass aBlockOrFunction 'Block') (isRunning this aBlockOrFunction)) {
		stopRunningChunk this chunkID
		runChunk this chunkID
	}
}

method saveVariableNames SmallRuntime {
	newVarNames = (allVariableNames (project scripter))
	if (oldVarNames == newVarNames) { return }

	varID = 0
	for varName newVarNames {
		if (notNil port) {
			sendMsgSync this 'varNameMsg' varID (toArray (toBinaryData varName))
		}
		varID += 1
	}
	oldVarNames = (copy newVarNames)
}

method runChunk SmallRuntime chunkID {
	sendMsg this 'startChunkMsg' chunkID
}

method stopRunningChunk SmallRuntime chunkID {
	sendMsg this 'stopChunkMsg' chunkID
}

method sendBroadcastToBoard SmallRuntime msg {
	sendMsg this 'broadcastMsg' 0 (toArray (toBinaryData msg))
}

method getVar SmallRuntime varID {
	if (isNil varID) { varID = 0 }
	sendMsg this 'getVarMsg' varID
}

method setVar SmallRuntime varID val {
	body = nil
	if (isClass val 'Integer') {
		body = (newArray 5)
		atPut body 1 1 // type 1 - Integer
		atPut body 2 (val & 255)
		atPut body 3 ((val >> 8) & 255)
		atPut body 4 ((val >> 16) & 255)
		atPut body 5 ((val >> 24) & 255)
	} (isClass val 'String') {
		body = (toArray (toBinaryData (join (string 2) val)))
	} (isClass val 'Boolean') {
		body = (newArray 2)
		atPut body 1 3 // type 3 - Boolean
		if val {
			atPut body 2 1 // true
		} else {
			atPut body 2 0 // false
		}
	}
	if (notNil body) { sendMsg this 'setVarMsg' varID body }
}

method clearVariableNames SmallRuntime {
	oldVarNames = nil
	if (notNil port) {
		sendMsgSync this 'clearVarsMsg'
	}
}

method getAllVarNames SmallRuntime {
	sendMsg this 'getVarNamesMsg'
}

// Message handling

method msgNameToID SmallRuntime msgName {
	if (isNil msgDict) {
		msgDict = (dictionary)
		atPut msgDict 'chunkCodeMsg' 1
		atPut msgDict 'deleteChunkMsg' 2
		atPut msgDict 'startChunkMsg' 3
		atPut msgDict 'stopChunkMsg' 4
		atPut msgDict 'startAllMsg' 5
		atPut msgDict 'stopAllMsg' 6
		atPut msgDict 'getVarMsg' 7
		atPut msgDict 'setVarMsg' 8
		atPut msgDict 'getVarNamesMsg' 9
		atPut msgDict 'clearVarsMsg' 10
		atPut msgDict 'getVersionMsg' 12
		atPut msgDict 'getAllCodeMsg' 13
		atPut msgDict 'deleteAllCodeMsg' 14
		atPut msgDict 'systemResetMsg' 15
		atPut msgDict 'taskStartedMsg' 16
		atPut msgDict 'taskDoneMsg' 17
		atPut msgDict 'taskReturnedValueMsg' 18
		atPut msgDict 'taskErrorMsg' 19
		atPut msgDict 'outputValueMsg' 20
		atPut msgDict 'varValueMsg' 21
		atPut msgDict 'versionMsg' 22
		atPut msgDict 'pingMsg' 26
		atPut msgDict 'broadcastMsg' 27
		atPut msgDict 'chunkAttributeMsg' 28
		atPut msgDict 'varNameMsg' 29
		atPut msgDict 'extendedMsg' 30
	}
	msgType = (at msgDict msgName)
	if (isNil msgType) { error 'Unknown message:' msgName }
	return msgType
}

method errorString SmallRuntime errID {
	// Return an error string for the given errID from error definitions copied and pasted from interp.h

	defsFromHeaderFile = '
#define noError					0	// No error
#define unspecifiedError		1	// Unknown error
#define badChunkIndexError		2	// Unknown chunk index

#define insufficientMemoryError	10	// Insufficient memory to allocate object
#define needsArrayError			11	// Needs a list
#define needsBooleanError		12	// Needs a boolean
#define needsIntegerError		13	// Needs an integer
#define needsStringError		14	// Needs a string
#define nonComparableError		15	// Those objects cannot be compared for equality
#define arraySizeError			16	// List size must be a non-negative integer
#define needsIntegerIndexError	17	// List index must be an integer
#define indexOutOfRangeError	18	// List index out of range
#define byteArrayStoreError		19	// A ByteArray can only store integer values between 0 and 255
#define hexRangeError			20	// Hexadecimal input must between between -1FFFFFFF and 1FFFFFFF
#define i2cDeviceIDOutOfRange	21	// I2C device ID must be between 0 and 127
#define i2cRegisterIDOutOfRange	22	// I2C register must be between 0 and 255
#define i2cValueOutOfRange		23	// I2C value must be between 0 and 255
#define notInFunction			24	// Attempt to access an argument outside of a function
#define badForLoopArg			25	// for-loop argument must be a positive integer or list
#define stackOverflow			26	// Insufficient stack space
#define primitiveNotImplemented	27	// Primitive not implemented in this virtual machine
#define notEnoughArguments		28	// Not enough arguments passed to primitive
#define waitTooLong				29	// The maximum wait time is 3600000 milliseconds (one hour)
#define noWiFi					30	// This board does not support WiFi
#define zeroDivide				31	// Division (or modulo) by zero is not defined
#define argIndexOutOfRange		32	// Argument index out of range
'
	for line (lines defsFromHeaderFile) {
		words = (words line)
		if (and ((count words) > 2) ('#define' == (first words))) {
			if (errID == (toInteger (at words 3))) {
				msg = (joinStrings (copyFromTo words 5) ' ')
				return (join 'Error: ' msg)
			}
		}
	}
	return (join 'Unknown error: ' errID)
}

method sendMsg SmallRuntime msgName chunkID byteList {
	ensurePortOpen this
	if (isNil port) { return }

	if (isNil chunkID) { chunkID = 0 }
	msgID = (msgNameToID this msgName)
	if (isNil byteList) { // short message
		msg = (list 250 msgID chunkID)
	} else { // long message
		byteCount = ((count byteList) + 1)
		msg = (list 251 msgID chunkID (byteCount & 255) ((byteCount >> 8) & 255))
		addAll msg byteList
		add msg 254 // terminator byte (helps board detect dropped bytes)
	}
	dataToSend = (toBinaryData (toArray msg))
	while ((byteCount dataToSend) > 0) {
		// Note: AdaFruit USB-serial drivers on Mac OS locks up if >= 1024 bytes
		// written in one call to writeSerialPort, so send smaller chunks
		byteCount = (min 1000 (byteCount dataToSend))
		chunk = (copyFromTo dataToSend 1 byteCount)
		bytesSent = (writeSerialPort port chunk)
		if (not (isOpenSerialPort port)) {
			closePort this
			return
		}
		if (bytesSent < byteCount) { waitMSecs 200 } // output queue full; wait a bit
		dataToSend = (copyFromTo dataToSend (bytesSent + 1))
	}
}

method sendMsgSync SmallRuntime msgName chunkID byteList {
	// Send a message followed by a 'pingMsg', then a wait for a ping response from VM.

	readAvailableSerialData this
	sendMsg this msgName chunkID byteList
	sendMsg this 'pingMsg'
	waitForResponse this
}

method readAvailableSerialData SmallRuntime {
	// Read any available data into recvBuf so that waitForResponse well await fresh data.

	if (isNil port) { return }
	waitMSecs 20 // leave some time for queued data to arrive
	if (isNil recvBuf) { recvBuf = (newBinaryData 0) }
	s = (readSerialPort port true)
	if (notNil s) { recvBuf = (join recvBuf s) }
}

method waitForResponse SmallRuntime {
	// Wait for some data to arrive from the board. This is taken to mean that the
	// previous operation has completed.

	if (isNil port) { return }
	timeout = 2000
	start = (msecsSinceStart)
	while (((msecsSinceStart) - start) < timeout) {
		s = (readSerialPort port true)
		if (notNil s) {
			recvBuf = (join recvBuf s)
			return
		}
		waitMSecs 5
	}
}

method ensurePortOpen SmallRuntime {
	if (or (isNil port) (not (isOpenSerialPort port))) {
		if (and (notNil portName) (contains (portList this) portName)) {
			port = (safelyRun (action 'openSerialPort' portName 115200))
			if (not (isClass port 'Integer')) { port = nil } // failed
			disconnected = false
			if ('Browser' == (platform)) { waitMSecs 100 } // let browser callback complete
		}
	}
	if (notNil port) {
		setSerialPortDTR port false
		setSerialPortRTS port false
	}
}

method processMessages SmallRuntime {
	if (isNil recvBuf) { recvBuf = (newBinaryData 0) }
	processingMessages = true
	count = 0
	while (and processingMessages (count < 10)) {
		processingMessages = (processNextMessage this)
		count += 1
	}
}

method processNextMessage SmallRuntime {
	// Process the next message, if any. Return false when there are no more messages.

	if (or (isNil port) (not (isOpenSerialPort port))) { return false }

	// Read any available bytes and append to recvBuf
	s = (readSerialPort port true)
	if (notNil s) { recvBuf = (join recvBuf s) }
	if ((byteCount recvBuf) < 3) { return false } // not enough bytes for even a short message

	// Parse and dispatch messages
	firstByte = (byteAt recvBuf 1)
	if (250 == firstByte) { // short message
		msg = (copyFromTo recvBuf 1 3)
		recvBuf = (copyFromTo recvBuf 4) // remove message
		handleMessage this msg
	} (251 == firstByte) { // long message
		if ((byteCount recvBuf) < 5) { return false } // incomplete length field
		byteTwo = (byteAt recvBuf 2)
		if (or (byteTwo < 1) (byteTwo > 32)) {
			print 'Bad message type; should be 1-31 but is:' (byteAt recvBuf 2)
			skipMessage this // discard unrecognized message
			return true
		}
		bodyBytes = (((byteAt recvBuf 5) << 8) | (byteAt recvBuf 4))
		if ((byteCount recvBuf) < (5 + bodyBytes)) { return false } // incomplete body
		msg = (copyFromTo recvBuf 1 (bodyBytes + 5))
		recvBuf = (copyFromTo recvBuf (bodyBytes + 6)) // remove message
		handleMessage this msg
	} else {
		print 'Bad message start byte; should be 250 or 251 but is:' firstByte
		print (toString recvBuf) // show the bad string (could be an ESP error message)
		skipMessage this // discard
	}
	return true
}

method skipMessage SmallRuntime {
	// Discard bytes in recvBuf until the start of the next message, if any.

	end = (byteCount recvBuf)
	i = 2
	while (i < end) {
		byte = (byteAt recvBuf i)
		if (or (250 == byte) (251 == byte)) {
			recvBuf = (copyFromTo recvBuf i)
			return
		}
		i += 1
	}
	recvBuf = (newBinaryData 0) // no message start found; discard entire buffer
}

method handleMessage SmallRuntime msg {
	op = (byteAt msg 2)
	if (op == (msgNameToID this 'taskStartedMsg')) {
		updateRunning this (byteAt msg 3) true
	} (op == (msgNameToID this 'taskDoneMsg')) {
		updateRunning this (byteAt msg 3) false
	} (op == (msgNameToID this 'taskReturnedValueMsg')) {
		chunkID = (byteAt msg 3)
		showResult this chunkID (returnedValue this msg)
		updateRunning this chunkID false
	} (op == (msgNameToID this 'taskErrorMsg')) {
		chunkID = (byteAt msg 3)
		showResult this chunkID (errorString this (byteAt msg 6))
		updateRunning this chunkID false
	} (op == (msgNameToID this 'outputValueMsg')) {
		chunkID = (byteAt msg 3)
		if (chunkID == 255) {
			print (returnedValue this msg)
		} (chunkID == 254) {
			addLoggedData this (toString (returnedValue this msg))
		} else {
			showResult this chunkID (returnedValue this msg)
		}
	} (op == (msgNameToID this 'varValueMsg')) {
		varValueReceived (thingServer scripter) (byteAt msg 3) (returnedValue this msg)
	} (op == (msgNameToID this 'versionMsg')) {
		versionReceived this (returnedValue this msg)
	} (op == (msgNameToID this 'pingMsg')) {
		lastPingRecvMSecs = (msecsSinceStart)
	} (op == (msgNameToID this 'broadcastMsg')) {
		broadcastReceived (thingServer scripter) (toString (copyFromTo msg 6))
	} (op == (msgNameToID this 'chunkCodeMsg')) {
		print 'chunkCodeMsg:' (byteCount msg) 'bytes'
	} (op == (msgNameToID this 'chunkAttributeMsg')) {
		print 'chunkAttributeMsg:' (byteCount msg) 'bytes'
	} (op == (msgNameToID this 'varNameMsg')) {
		print 'varNameMsg:' (byteAt msg 3) (toString (copyFromTo msg 6)) ((byteCount msg) - 5) 'bytes'
	} else {
		print 'msg:' (toArray msg)
	}
}

method updateRunning SmallRuntime chunkID runFlag {
	if (isNil chunkRunning) {
		chunkRunning = (newArray 256 false)
	}
	atPut chunkRunning (chunkID + 1) runFlag
	updateHighlights this
}

method isRunning SmallRuntime aBlock {
	chunkID = (lookupChunkID this aBlock)
	if (or (isNil chunkRunning) (isNil chunkID)) { return false }
	return (at chunkRunning (chunkID + 1))
}

method allStopped SmallRuntime {
	chunkRunning = (newArray 256 false) // clear all running flags
	updateHighlights this
}

method updateHighlights SmallRuntime {
	scale = (global 'scale')
	for m (parts (morph (scriptEditor scripter))) {
		if (isClass (handler m) 'Block') {
			if (isRunning this (handler m)) {
				addHighlight m (4 * scale)
			} else {
				removeHighlight m
			}
		}
	}
}

method showResult SmallRuntime chunkID value {
	for m (join
			(parts (morph (scriptEditor scripter)))
			(parts (morph (blockPalette scripter)))) {
		h = (handler m)
		if (and (isClass h 'Block') (chunkID == (lookupChunkID this h))) {
			showHint m value
			if ('' == value) { removeHint (global 'page') }
		}
	}
}

method returnedValue SmallRuntime msg {
	if (byteCount msg < 7) { return nil } // incomplete msg
	type = (byteAt msg 6)
	if (1 == type) {
		return (+ ((byteAt msg 10) << 24) ((byteAt msg 9) << 16) ((byteAt msg 8) << 8) (byteAt msg 7))
	} (2 == type) {
		return (toString (copyFromTo msg 7))
	} (3 == type) {
		return (0 != (byteAt msg 7))
	} (4 == type) {
		return (toArray (copyFromTo msg 7))
	} (5 == type) {
		// xxx Arrays are not yet fully handled
		intArraySize = (truncate (((byteCount msg) - 6) / 5))
		return (join 'list of ' intArraySize ' items')
	} else {
		return (join 'unknown type: ' type)
	}
}

method showOutputStrings SmallRuntime {
	// For debuggong. Just display incoming characters.
	if (isNil port) { return }
	s = (readSerialPort port)
	if (notNil s) {
		if (isNil recvBuf) { recvBuf = '' }
		recvBuf = (toString recvBuf)
		recvBuf = (join recvBuf s)
		while (notNil (findFirst recvBuf (newline))) {
			i = (findFirst recvBuf (newline))
			out = (substring recvBuf 1 (i - 2))
			recvBuf = (substring recvBuf (i + 1))
			print out
		}
	}
}

// Virtual Machine Installer

method installVM SmallRuntime {
	disconnected = true

	if ('Browser' == (platform)) {
		installVMInBrowser this
		return
	}
	boards = (collectBoardDrives this)
	if ((count boards) > 0) {
		menu = (menu 'Select board:' this)
		for b boards {
			addItem menu (niceBoardName this b) (action 'copyVMToBoard' this (first b) (last b))
		}
		popUpAtHand menu (global 'page')
	} ((count (portList this)) > 0) {
		if (contains (array 'ESP8266' 'ESP32' 'Citilab ED1') boardType) {
			flashVM this boardType
		} (isNil boardType) {
			menu = (menu 'Select board type:' this)
			for boardName (array 'ESP8266' 'ESP32' 'Citilab ED1') {
				addItem menu boardName (action 'flashVM' this boardName)
			}
			addLine menu
			addItem menu 'AdaFruit Board' (action 'adaFruitMessage' this)
			popUpAtHand menu (global 'page')
		}
	} else {
		inform (join
			(localized 'No boards found; is your board plugged in?') (newline)
			(localized 'For AdaFruit boards, double-click reset button and try again.'))
	}
}

method niceBoardName SmallRuntime board {
	name = (first board)
	if (beginsWith name 'MICROBIT') {
		return 'BBC micro:bit'
	} (beginsWith name 'MINI') {
		return 'Calliope mini'
	} (beginsWith name 'CPLAYBOOT') {
		return 'Circuit Playground Express'
	}
	return name
}

method collectBoardDrives SmallRuntime {
	result = (list)
	if ('Mac' == (platform)) {
		for v (listDirectories '/Volumes') {
			path = (join '/Volumes/' v '/')
			boardName = (getBoardName this path)
			if (notNil boardName) { add result (list boardName path) }
		}
	} ('Linux' == (platform)) {
		for dir (listDirectories '/media') {
			prefix = (join '/media/' dir)
			for v (listDirectories prefix) {
				path = (join prefix '/' v '/')
				boardName = (getBoardName this path)
				if (notNil boardName) { add result (list boardName path) }
			}
		}
	} ('Win' == (platform)) {
		for letter (range 65 90) {
			drive = (join (string letter) ':')
			boardName = (getBoardName this drive)
			if (notNil boardName) { add result (list boardName drive) }
		}
	}
	return result
}

method getBoardName SmallRuntime path {
	for fn (listFiles path) {
		if ('MICROBIT.HTM' == fn) { return 'MICROBIT' }
		if ('MINI.HTM' == fn) { return 'MINI' }
		if ('INFO_UF2.TXT' == fn) {
			contents = (readFile (join path fn))
			if (notNil (nextMatchIn 'CPlay Express' contents)) { return 'CPLAYBOOT' }
		}
	}
	return nil
}

method copyVMToBoard SmallRuntime boardName boardPath {
	if (beginsWith boardName 'MICROBIT') {
		vmFileName = 'vm.ino.BBCmicrobit.hex'
	} (beginsWith boardName 'MINI') {
		vmFileName = 'vm.ino.Calliope.hex'
	} (beginsWith boardName 'CPLAYBOOT') {
		vmFileName = 'vm.circuitplay.uf2'
	}
	if (notNil vmFileName) {
		if ('Browser' == (platform)) {
			vmData = (readFile (join 'precompiled/' vmFileName) true)
		} else {
			vmData = (readEmbeddedFile (join 'precompiled/' vmFileName) true)
		}
	}
	if (isNil vmData) {
		error (join (localized 'Could not read: ') (join 'precompiled/' vmFileName))
	}
	stopAndSyncScripts this
	closePort (smallRuntime)
	writeFile (join boardPath vmFileName) vmData
	print 'Installed' (join boardPath vmFileName) (join '(' (byteCount vmData) ' bytes)')

	waitMSecs 8000 // leave time for installation and VM startup
}

method installVMInBrowser SmallRuntime {
	menu = (menu 'Board type:' (action 'downloadVMFile' this) true)
	addItem menu 'BBC micro:bit'
	addItem menu 'Calliope mini'
	addItem menu 'Circuit Playground Express'
	popUpAtHand menu (global 'page')
}

method downloadVMFile SmallRuntime boardName {
	if ('BBC micro:bit' == boardName) {
		vmFileName = 'vm.ino.BBCmicrobit.hex'
	} ('Calliope mini' == boardName) {
		vmFileName = 'vm.ino.Calliope.hex'
	} ('Circuit Playground Express' == boardName) {
		vmFileName = 'vm.circuitplay.uf2'
	}
	vmData = (readFile (join 'precompiled/' vmFileName) true)
	writeFile vmFileName vmData
	inform (join
		'To install MicroBlocks, drag "' vmFileName '" from your Downloads' (newline)
		'folder onto the USB drive for your board. It may take 15-30 seconds' (newline)
		'to copy the file, then the USB drive for your board will dismount.' (newline)
		'When it remounts, MicroBLocks should reconnect to the board.')
}

method adaFruitMessage SmallRuntime {
	inform (localized 'For AdaFruit boards, double-click reset button and try again.')
}

method esptoolCommandName SmallRuntime {
    if ('Mac' == (platform)) {
        return 'esptool'
    } ('Linux' == (platform)) {
        return 'esptool.py'
    } ('Win' == (platform)) {
        return 'esptool.exe'
    }
    return ''
}

method repartitionFlash SmallRuntime boardName {
    stopAndSyncScripts this
    closePort (smallRuntime)
    copyEspToolToDisk this
    copyEspFilesToDisk this

    esptool = (join (tmpPath this) (esptoolCommandName this))

    commands = (array
        (array esptool '-b' '921600' 'write_flash' '0x0e00' (join (tmpPath this) 'boot_app0.bin'))
        (array esptool '-b' '921600' 'write_flash' '0x1000' (join (tmpPath this) 'bootloader_dio_80m.bin'))
        (array esptool '-b' '921600' 'write_flash' '0x8000' (join (tmpPath this) 'partitions.bin')))

    for command commands {
        processPID = (call (new 'Action' 'exec' command))
        processStatus = (execStatus processPID)
        while (processStatus == nil) {
            print 'repartitioning ...'
            waitMSecs 500
            processStatus = (execStatus processPID)
        }
        if (processStatus == 1) {
            error (join 'Command ' (joinStrings command ' ') ' failed')
        } else {
            print (join 'Command ' (joinStrings command ' ') ' done')
        }
    }
    inform (localized 'Board has been wiped and repartitioned.')
}

method flashVM SmallRuntime boardName {
    stopAndSyncScripts this
    closePort (smallRuntime)
    copyEspToolToDisk this
    copyVMtoDisk this boardName

    esptool = (join (tmpPath this) (esptoolCommandName this))
    address = '0x10000' // for ESP32-based boards

    //page = (global 'page')
    //m = (newMorph)
    //addPart page m
    //redraw m
    //addSchedule (global 'page') (newAnimation 0 1000 500 (action 'setLeft' m))

    if (boardName == 'ESP8266') { address = '0' }

    processPID = (exec esptool '-b' '921600' 'write_flash' address (join (tmpPath this) 'vm'))
        processStatus = (execStatus processPID)
        while (processStatus == nil) {
            print 'flashing ...'
            waitMSecs 500
            processStatus = (execStatus processPID)
        }
    if (processStatus == 1) {
        error (join 'Command ' (joinStrings command ' ') ' failed')
    } else {
        print (join 'VM flashed: ' processStatus)
        inform (localized 'Firmware installed.')
    }
}

method tmpPath SmallRuntime {
	if (or ('Mac' == (platform)) ('Linux' == (platform))) {
		return '/tmp/'
	} else { // Windows
		return (join (userHomePath) '/AppData/Local/Temp/')
	}
}

method copyEspToolToDisk SmallRuntime {
	if ('Mac' == (platform)) {
		esptoolData = (readEmbeddedFile 'esptool/esptool' true)
		destination = (join (tmpPath this) 'esptool')
	} ('Linux' == (platform)) {
		esptoolData = (readEmbeddedFile 'esptool/esptool.py')
		destination = (join (tmpPath this) 'esptool.py')
	} ('Win' == (platform)) {
		esptoolData = (readEmbeddedFile 'esptool/esptool.exe' true)
		destination = (join (tmpPath this) 'esptool.exe')
	}
	writeFile destination esptoolData
	setFileMode destination (+ (7 << 6) (5 << 3) 5) // set executable bits
}

method copyVMtoDisk SmallRuntime boardName {
	if (boardName == 'ESP8266') {
		vmData = (readEmbeddedFile 'precompiled/vm.ino.nodemcu.bin' true)
	} (boardName == 'ESP32') {
		vmData = (readEmbeddedFile 'precompiled/vm.ino.esp32.bin' true)
	} (boardName == 'Citilab ED1') {
		vmData = (readEmbeddedFile 'precompiled/vm.ino.citilab-ed1.bin' true)
	}
	writeFile (join (tmpPath this) 'vm') vmData
}

method copyEspFilesToDisk SmallRuntime {
	for fn (array 'boot_app0.bin' 'bootloader_dio_80m.bin' 'ed1_1000.bin' 'ed1_8000.bin' 'ed1_E00.bin' 'partitions.bin') {
		fileData = (readEmbeddedFile (join 'esp32/' fn) true)
		writeFile (join (tmpPath this) fn) fileData
	}
}

// data logging

method lastDataIndex SmallRuntime { return loggedDataNext }

method clearLoggedData SmallRuntime {
	loggedData = (newArray 10000)
	loggedDataNext = 1
	loggedDataCount = 0
}

method addLoggedData SmallRuntime s {
	atPut loggedData loggedDataNext s
	loggedDataNext = ((loggedDataNext % (count loggedData)) + 1)
	if (loggedDataCount < (count loggedData)) { loggedDataCount += 1 }
}

method loggedData SmallRuntime howMany {
	if (or (isNil howMany) (howMany > loggedDataCount)) {
		howMany = loggedDataCount
	}
	result = (newArray howMany)
	start = (loggedDataNext - howMany)
	if (start > 0) {
		replaceArrayRange result 1 howMany loggedData start
	} else {
		tailCount = (- start)
		tailStart = (((count loggedData) - tailCount) + 1)
		replaceArrayRange result 1 tailCount loggedData tailStart
		replaceArrayRange result (tailCount + 1) howMany loggedData 1
	}
	return result
}
