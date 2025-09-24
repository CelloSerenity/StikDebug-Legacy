
function littleEndianHexStringToNumber(hexStr) {
    // Convert hex string to byte array
    const bytes = [];
    for (let i = 0; i < hexStr.length; i += 2) {
        bytes.push(parseInt(hexStr.substr(i, 2), 16));
    }

    // Assemble number from first 5 bytes (little-endian)
    let num = 0n;
    for (let i = 4; i >= 0; i--) {
        num = (num << 8n) | BigInt(bytes[i]);
    }

    return num; // BigInt: 0x01016644fc
}

function numberToLittleEndianHexString(num) {
    // Extract 5 bytes in little-endian order
    const bytes = [];
    for (let i = 0; i < 5; i++) {
        bytes.push(Number(num & 0xFFn));
        num >>= 8n;
    }

    // Pad with 3 zero bytes to make 8 bytes
    while (bytes.length < 8) {
        bytes.push(0);
    }

    // Convert to hex string
    return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
}

function attach() {
    let pid = get_pid();
    log(`pid = ${pid}`)

    // attach
    let attachResponse = send_command(`vAttach;${pid.toString(16)}`)
    log(`attach_response = ${attachResponse}`)

    // wait for brk
    let brkResponse = send_command(`c`)
    log(`brkResponse = ${brkResponse}`)

    let tid = /T[0-9a-f]+thread:(?<tid>[0-9a-f]+);/.exec(brkResponse).groups['tid']
    let pc = /20:(?<reg>[0-9a-f]{16});/.exec(brkResponse).groups['reg']
    let x0 = /00:(?<reg>[0-9a-f]{16});/.exec(brkResponse).groups['reg']

    log(`tid = ${tid}, pc = ${littleEndianHexStringToNumber(pc).toString(16)}, x0 = ${littleEndianHexStringToNumber(x0).toString(16)}`)

    pc = numberToLittleEndianHexString(littleEndianHexStringToNumber(pc) + BigInt(4))
    let x0Num = littleEndianHexStringToNumber(x0)

    // pc+4
    let pcPlus4Response = send_command(`P20=${pc};thread:${tid};`)
    log(`pcPlus4Response = ${pcPlus4Response}`)

    // apply for jit page of requested size
    let requestRXResponse = send_command(`_M${x0Num.toString(16)},rx`)
    log(`requestRXResponse = ${requestRXResponse}`)
    let jitPageAddress = BigInt(`0x${requestRXResponse}`)

    // TODO fill the page
    let a = 0;
    try {
        for(let i = 0n; i < x0Num; i += 16384n) {
            let curPointer = jitPageAddress + i;
            let response = send_command(`M${curPointer.toString(16)},1:69`)
            if(a % 1000 == 0) {
                log(`progress: ${a}/${Math.ceil(Number(x0Num / BigInt(16384)))}, response = ${response}`)
            }
            ++a;
        }
        log(`memory write completed. command executed: ${a}`)
    }catch(e) {
        log(`memory write failed at command ${a}`)
    }

    // put page address in x0
    let putX0Response = send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`)
    log(`putX0Response = ${putX0Response}`)
    // detach
    let detachResponse = send_command(`D`)
    log(`detachResponse = ${detachResponse}`)
}

attach()