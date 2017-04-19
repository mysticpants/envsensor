// Copyright (c) 2017 Mystic Pants Pty Ltd
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

// Debugging
#require "JSONEncoder.class.nut:1.0.0"
#require "PrettyPrinter.class.nut:1.0.1"

// Import Libraries
#require "ConnectionManager.class.nut:1.0.2"
#require "WS2812.class.nut:2.0.2"
#require "HTS221.class.nut:1.0.0"
#require "LPS22HB.class.nut:1.0.0"
#require "LIS3DH.class.nut:1.3.0"
#include "include/defaults.nut"


// Constants
const LPS22HB_ADDR = 0xB8;
const LIS3DH_ADDR = 0x32;
const POLL_TIME = 900;
const VOLTAGE_VARIATION = 0.1;
const NO_WIFI_SLEEP_DURATION = 60;
const DEBUG = true;

enum DeviceType {
    environmentSensor,
    impExplorer
}

class environmentSensor {

    reading = null;
    config = null;

    _sleepTime = POLL_TIME;
    _processesRunning = null;
    _pollRunning = false;

    constructor() {

        reading = {
            "pressure": null,
            "temperature": null,
            "humidity": null,
            "battery": null,
            "acceleration_x": null,
            "acceleration_y": null,
            "acceleration_z": null,
            "light": null
        }


        config = {
            "pollFreq1": DEFAULT_POLLFREQ1,
            "pollFreq2": DEFAULT_POLLFREQ2,
            "pollFreq3": DEFAULT_POLLFREQ3,
            "pollFreq4": DEFAULT_POLLFREQ4,
            "pollFreq5": DEFAULT_POLLFREQ5,
            "green": 1,
            "blue": 1,
            "ledBlueEnabled": true,
            "ledGreenEnabled": true,
            "tapSensitivity": 2,
            "tapEnabled": true,
        }

        _processesRunning = 0;

        agent.on("config", setConfig.bindenv(this));
    }

    // function that requests agent for configs
    // 
    // @params none
    // @returns none
    // 
    function init() {
        agent.send("ready", "ready");
    }

    // function that sets the configs
    //  
    // @param  newconfig - object containing the new configurations
    // @returns none
    // 
    function setConfig(newconfig) {
        if (DEBUG) server.log("Setting Configs");
        if (typeof newconfig == "table") {

            foreach (k, v in newconfig) {
                config[k] <- v;
            }
            if (config.tapEnabled) {
                accel.configureClickInterrupt(true, LIS3DH.DOUBLE_CLICK, config.tapSensitivity, 15, 10, 300);
            } else {
                accel.configureClickInterrupt(false);
            }
        }

        poll();
    }

    // function that takes the sensor readings
    // 
    // @param     none
    // @returns   none
    // 
    function poll() {

        if (_pollRunning) return;
        _pollRunning = true;
        _processesRunning = 0;

        // Get the accelerometer data
        _processesRunning++;
        accel.getAccel(function(val) {
            reading.acceleration_x = val.x;
            reading.acceleration_y = val.y;
            reading.acceleration_z = val.z;
            // server.log(format("Acceleration (G): (%0.2f, %0.2f, %0.2f)", val.x, val.y, val.z));

            decrementProcesses();
        }.bindenv(this));

        // Get the temp and humid data
        _processesRunning++;
        tempHumid.read(function(result) {
            if ("error" in result) {
                server.log("tempHumid: " + result.error);
            } else {
                // This temp sensor has 0.5 accuracy so it is used for 0-40 degrees.
                reading.temperature = result.temperature;
                reading.humidity = result.humidity;
                if (DEBUG) server.log(format("Current Humidity: %0.2f %s, Current Temperature: %0.2f °C", result.humidity, "%", result.temperature));
            }

            decrementProcesses();
        }.bindenv(this));

        // Get the pressure data
        _processesRunning++;
        pressureSensor.read(function(result) {
            if ("err" in result) {
                if (DEBUG) server.log("pressureSensor: " + result.err);
            } else {
                // Note the temp sensor in the LPS22HB is only accurate to +-1.5 degrees. 
                // But it has an range of up to 65 degrees.
                // Hence it is used if temp is greater than 40.
                if (result.temperature > 40) reading.temperature = result.temperature;
                reading.pressure = result.pressure;
                if (DEBUG) server.log(format("Current Pressure: %0.2f hPa, Current Temperature: %0.2f °C", result.pressure, result.temperature));
            }

            decrementProcesses();
        }.bindenv(this));

        // Read the light level
        reading.light = hardware.lightlevel();
        if (DEBUG) server.log("Ambient Light: " + reading.light);

        // Read the battery voltage
        if (deviceType == DeviceType.environmentSensor) {
            reading.battery = getBattVoltage();
            if (DEBUG) server.log(reading.battery);
            // Determine how long to sleep for
            _sleepTime = calcSleepTime(reading.battery);
        } else {
            reading.battery = 0;
            _sleepTime = DEFAULT_POLLFREQ5;
        }


        // Toggle the LEDs
        if (deviceType == DeviceType.environmentSensor) {
            ledgreen.write(0);
            ledblue.write(0);
        } else {
            hardware.pin1.configure(DIGITAL_OUT, 1);
            rgbLED.set(0, [0, 255, 255]).draw();
        }

        _processesRunning++;
        imp.wakeup(1.0, function() {
            // TODO: Implement changing LED blink duration.
            if (deviceType == DeviceType.environmentSensor) {
                ledgreen.write(1);
                ledblue.write(1);
            } else {
                hardware.pin1.configure(DIGITAL_OUT, 0);

            }

            decrementProcesses();
        }.bindenv(this));


    }

    // function that posts the readings
    // 
    // @param     none
    // @returns   none
    // 
    function postReadings() {
        agent.send("reading", reading);
        wakepin.configure(DIGITAL_IN_WAKEUP);
        server.flush(10);
        server.sleepfor(NO_WIFI_SLEEP_DURATION);
    }


    // function that reads the battery voltage
    // 
    // @param     none
    // @returns   battVoltage - the detected battery voltage
    // 
    function getBattVoltage() {
        local firstRead = batt.read() / 65535.0 * hardware.voltage();
        local battVoltage = batt.read() / 65535.0 * hardware.voltage();
        local pollArray = [];
        if (math.abs(firstRead - battVoltage) < VOLTAGE_VARIATION) {
            return battVoltage;
        } else {
            for (local i = 0; i < 10; i++) {
                pollArray.append(batt.read() / 65535.0 * hardware.voltage());
            }
            return takeAverage(pollArray);
        }
    }

    // function posts readings if no more processes are running
    // 
    // @param     none
    // @returns   none
    // 
    function decrementProcesses() {
        if (--_processesRunning <= 0) {
            if (cm.isConnected()) {
                postReadings();   
            } else {
                // TODO Handle not connected to wifi
                cm.onNextConnect(postReadings.bindenv(this)).connect();
            }

        }
    }

    // function that calculates sleep time
    // 
    // @param     battVoltage - the read battery voltage
    // @returns    _sleeptime - duration for the imp to sleep
    // 
    function calcSleepTime(battVoltage) {
        local _sleepTime;
        if (battVoltage < 0.8) {
            // Poll only once every two days
            _sleepTime = config.pollFreq1;
            if (DEBUG) server.log("Battery Voltage Critical: " + battVoltage);
        } else if (battVoltage < 1.5) {
            // Poll only once every day
            _sleepTime = config.pollFreq2;
            if (DEBUG) server.log("Battery Voltage Low: " + battVoltage);
        } else if (battVoltage < 2.0) {
            // Poll only once every 5 hours
            _sleepTime = config.pollFreq3;
            if (DEBUG) server.log("Battery Voltage Medium: " + battVoltage);
        } else if (battVoltage < 2.5) {
            // Poll only once an hour
            _sleepTime = config.pollFreq4;
            if (DEBUG) server.log("Battery Voltage High: " + battVoltage);
        } else {
            if (DEBUG) server.log("Battery Voltage Full: " + battVoltage);
            // Poll every 15 min
            _sleepTime = config.pollFreq5;
        }

        return _sleepTime;
    }


    // function that returns an average of an array
    // 
    // @param     array - input array of numbers
    // @returns average - average of array
    // 
    function takeAverage(array) {
        local sum = 0;
        local average = 0
        for (local i = 0; i < array.len(); i++) {
            sum += array[i];
        }
        average = sum / (array.len());
        return average
    }

}


// Globals
cm <- ConnectionManager({ "blinkupBehavior": ConnectionManager.BLINK_ALWAYS, "stayConnected": false });
imp.setsendbuffersize(8096);

// Checks hardware type
if ("pinW" in hardware) {
    deviceType <- DeviceType.environmentSensor;
} else {
    deviceType <- DeviceType.impExplorer;
}

// Configures the pins depending on device type
if (deviceType == DeviceType.environmentSensor) {
    batt <- hardware.pinH;
    batt.configure(ANALOG_IN);
    wakepin <- hardware.pinW;
    ledblue <- hardware.pinP;
    ledblue.configure(DIGITAL_OUT, 1);
    ledgreen <- hardware.pinU;
    ledgreen.configure(DIGITAL_OUT, 1);
    i2cpin <- hardware.i2cAB;
    i2cpin.configure(CLOCK_SPEED_400_KHZ);
} else {
    batt <- null;
    wakepin <- hardware.pin1;
    ledblue <- null;
    ledgreen <- null;
    i2cpin <- hardware.i2c89;
    i2cpin.configure(CLOCK_SPEED_400_KHZ);
    spi <- hardware.spi257;
    spi.configure(MSB_FIRST, 7500);
    rgbLED <- WS2812(spi, 1);
}

// Init Hardware
accel <- LIS3DH(i2cpin, LIS3DH_ADDR);
accel.setDataRate(100);
accel.configureClickInterrupt(true, LIS3DH.DOUBLE_CLICK, 2, 15, 10, 300);
accel.configureInterruptLatching(true);
pressureSensor <- LPS22HB(i2cpin, LPS22HB_ADDR);
tempHumid <- HTS221(i2cpin);
tempHumid.setMode(HTS221_MODE.ONE_SHOT, 7);

// DEBUGGING
pp <- PrettyPrinter(null, false);
print <- pp.print.bindenv(pp);

// Start the application
envSensor <- environmentSensor();
bootdelay <- 0;

// Delays code initalization after booting from power cycle, to allow for BlinkUps.
if (hardware.wakereason() == WAKEREASON_POWER_ON) bootdelay <- 20
imp.wakeup(bootdelay, function() {
    imp.onidle(function(){
        // Only does this if it's initially connected to wifi, so it only gets preferences on power cycle. 
        envSensor.init();
        envSensor.poll();
    }.bindenv(this));
}.bindenv(this));




