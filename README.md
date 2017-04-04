# Environmental Sensor #

### Sensors ###
The I2C sensors are all on i2cAB.
Use this setting for i2C clock speed `hardware.i2cAB.configure(CLOCK_SPEED_400_KHZ);`


### Sleep ###
The imp goes into deep sleep when after it takes some sensor readings. The wake pin is pinW. The accelerometer is setup to generate an interrupt when it recognizes a doubleClick.


### LEDs ###
There are two LEDs on the environmental sensor, a green LED and a blue LED. Both are active low.
The blue LED is on pinP.
The green LED is on pinU.


### Config Page ###
There is a user configuration page hosted by the agent.
