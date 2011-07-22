//**************************************************************
//  Name    : Sprinkler Controller
//  Author  : TJ Hunter <tjhunter@gmail.com>
//  Date    : 7/4/2011
//  Modified: 7/11/2011
//  Version : 0.02
//  Notes   : 
//          : 
//****************************************************************

#include <EEPROM.h> // For saving the schedule

#include <SPI.h>
#include <Ethernet.h>
#include <EthernetDHCP.h> // http://gkaindl.com/software/arduino-ethernet

#include <Wire.h>
#include "RTClib.h" // https://github.com/adafruit/RTClib
RTC_DS1307 RTC;
DateTime now;

// Ethernet settings
byte mac[] = { 0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED };
// byte ip[] = { 192,168,1,200 };
// byte gateway[] = { 192,168,1,1 };
// byte subnet[] = { 255,255,255,0 };

// Shift Register (Controls the Solid State Relays)
int latchPin = 8; // Pin connected to ST_CP of 74HC595
int clockPin = 7; // Pin connected to SH_CP of 74HC595
int dataPin = 6; // Pin connected to DS of 74HC595

// Bytes to send to the shift register to turn on the different zones
byte off = 0;
byte zone1 = 1 << 0;
byte zone2 = 1 << 1;
byte zone3 = 1 << 2;
byte zone4 = 1 << 3;
byte zone5 = 1 << 4;
byte zone6 = 1 << 5;
byte zone7 = 1 << 6;
byte zone8 = 1 << 7;

// Telnet server
Server server(23);
Client client = 0;
int clientConnected = 0;
unsigned long timeOfLastActivity; //time in milliseconds of last activity
unsigned long connectTimeout = 60 * 5; // 5 minutes
String command;

// Schedule
typedef struct {
  byte deleted;
  byte enabled;
  byte days; // 1 = Everyday, 2=Even Days, 3=Odd Days
  byte hour; // 0 - 23
  byte minute; // 0 - 59
  byte zone; // 0 - 8
} 
Schedule;

int workingScheduleNumber = 0;
Schedule workingSchedule;
#define SCHEDULELISTSIZE 64
Schedule scheduleList[SCHEDULELISTSIZE];

// State variables
int currentZone = 0;
int lastMinute = 0;
byte shellState = 0;
unsigned long startTime = 0; // Unixtime of power-up or last reset
unsigned long lastTimeCheck = 0;

// Strings
prog_char string_0[] PROGMEM = "\nWelcome to TJ's Sprinkler.\nThe current time is: ";
prog_char string_1[] PROGMEM = "Enter ? for help\n";
prog_char string_2[] PROGMEM = "\n\nTimeout disconnect.\n";
prog_char string_3[] PROGMEM = "Set Schedule ";
prog_char string_4[] PROGMEM = "Bytes free: ";
prog_char string_5[] PROGMEM = "Days:\n 1: Everyday\n 2: Even Days\n 3: Odd Days\nDays ";
prog_char string_6[] PROGMEM = "Hour ";
prog_char string_7[] PROGMEM = "Minute ";
prog_char string_8[] PROGMEM = "Zone (0 = off) ";
prog_char string_9[] PROGMEM = "Schedule set\n";
prog_char string_10[] PROGMEM = "Invalid command\n";
prog_char string_11[] PROGMEM = " | ";
prog_char string_12[] PROGMEM = "Schedule deleted\n";
prog_char string_13[] PROGMEM = "Schedule saved\n";
prog_char string_14[] PROGMEM = "Schedule loaded\n";
prog_char string_15[] PROGMEM = "Time set to: ";
prog_char string_16[] PROGMEM = "Schedule enabled\n";
prog_char string_17[] PROGMEM = "Schedule disabled\n";
prog_char string_18[] PROGMEM = "Today is an EVEN day.\n";
prog_char string_19[] PROGMEM = "Today is an ODD day.\n";

PROGMEM const char *string_table[] =
{   
  string_0,
  string_1,
  string_2,
  string_3,
  string_4,
  string_5,
  string_6,
  string_7,
  string_8,
  string_9,
  string_10,
  string_11,
  string_12,
  string_13,
  string_14,
  string_15,
  string_16,
  string_17,
  string_18,
  string_19
};

prog_char stringHelp_0[]  PROGMEM = "Available Commands:\n";
prog_char stringHelp_1[]  PROGMEM = "?                                  Display this help\n";
prog_char stringHelp_2[]  PROGMEM = "time                               Display current time\n";
prog_char stringHelp_3[]  PROGMEM = "settime <Mon dd YYYY HH:ii:ss>     Set current time\n";
prog_char stringHelp_4[]  PROGMEM = "mem                                Show free memory\n";
prog_char stringHelp_5[]  PROGMEM = "on <1-8>                           Turn on zone\n";
prog_char stringHelp_6[]  PROGMEM = "off                                Turn off all zones\n";
prog_char stringHelp_7[]  PROGMEM = "list                               List all schedules\n";
prog_char stringHelp_8[]  PROGMEM = "enable <1-64>                      Enable schedule\n";
prog_char stringHelp_9[]  PROGMEM = "disable <1-64>                     Disable schedule\n";
prog_char stringHelp_10[] PROGMEM = "set <1-64>                         Modify schedule\n";
prog_char stringHelp_11[] PROGMEM = "rm <1-64>                          Remove schedule\n";
prog_char stringHelp_12[] PROGMEM = "clearall                           Remove ALL schedules\n";
prog_char stringHelp_13[] PROGMEM = "load                               Load schedule from EEPROM\n";
prog_char stringHelp_14[] PROGMEM = "save                               Save schedule to EEPROM\n";
prog_char stringHelp_15[] PROGMEM = "exit                               Disconnect\n";

PROGMEM const char *stringHelp_table[] =
{
  stringHelp_0,
  stringHelp_1,
  stringHelp_2,
  stringHelp_3,
  stringHelp_4,
  stringHelp_5,
  stringHelp_6,
  stringHelp_7,
  stringHelp_8,
  stringHelp_9,
  stringHelp_10,
  stringHelp_11,
  stringHelp_12,
  stringHelp_13,
  stringHelp_14,
  stringHelp_15
};

char stringBuffer[70];

// Functions
int availableMemory() { // From http://www.faludi.com/itp/arduino/Arduino_Available_RAM_Test.pde
  int byteCounter = 0; // initialize a counter
  byte *byteArray; // create a pointer to a byte array
  // More on pointers here: http://en.wikipedia.org/wiki/Pointer#C_pointers

  // use the malloc function to repeatedly attempt allocating a certain number of bytes to memory
  // More on malloc here: http://en.wikipedia.org/wiki/Malloc
  while ( (byteArray = (byte*) malloc (byteCounter * sizeof(byte))) != NULL ) {
    byteCounter++; // if allocation was successful, then up the count for the next try
    free(byteArray); // free memory after allocating it
  }

  free(byteArray); // also free memory after the function finishes
  return byteCounter; // send back the highest number of bytes successfully allocated
}

void initializeSchedule() {
  for (int i = 0; i < SCHEDULELISTSIZE; i++) {
    scheduleList[i] = (Schedule){ 1,0,1,0,0,0 };
  }
}

void loadSchedule() {
  initializeSchedule();
  // Load schedule from EEPROM
  int addr = 0;

  for (int i = 0; i < SCHEDULELISTSIZE; i++) {
    scheduleList[i].deleted = EEPROM.read(addr++);
    scheduleList[i].enabled = EEPROM.read(addr++);
    scheduleList[i].days = EEPROM.read(addr++);
    scheduleList[i].hour = EEPROM.read(addr++);
    scheduleList[i].minute = EEPROM.read(addr++);
    scheduleList[i].zone = EEPROM.read(addr++);
  }
}

void saveSchedule() {
  // Save schedule to EEPROM
  int addr = 0;

  for (int i = 0; i < SCHEDULELISTSIZE; i++) {
    EEPROM.write(addr++, scheduleList[i].deleted);
    EEPROM.write(addr++, scheduleList[i].enabled);
    EEPROM.write(addr++, scheduleList[i].days);
    EEPROM.write(addr++, scheduleList[i].hour);
    EEPROM.write(addr++, scheduleList[i].minute);
    EEPROM.write(addr++, scheduleList[i].zone);
  }
}

void loadString(int i) {
  strcpy_P(stringBuffer, (char*)pgm_read_word(&(string_table[i])));
}

void loadHelpString(int i) {
  strcpy_P(stringBuffer, (char*)pgm_read_word(&(stringHelp_table[i])));
}

void e_printString(int i) { // Print PROGMEM string to ethernet port
  loadString(i);
  client.print(stringBuffer);
}

void e_printHelp() {
  for (int i = 0; i <= 15; i++) {
    e_printHelpString(i);
  }
}

void e_printHelpString(int i) { // Print PROGMEM string to ethernet port
  loadHelpString(i);
  client.print(stringBuffer);
}
void e_printTime() {
  // Month
  if (now.month() < 10) {
    client.print("0");
  }
  client.print(now.month(), DEC);
  client.print("/");

  // Day
  if (now.day() < 10) {
    client.print("0");
  }
  client.print(now.day(), DEC);
  client.print("/");

  // Year
  client.print(now.year(), DEC);
  client.print(" ");

  // Hour
  if (now.hour() < 10) {
    client.print("0");
  }
  client.print(now.hour(), DEC);
  client.print(":");

  // Minute
  if (now.minute() < 10) {
    client.print("0");
  }
  client.print(now.minute(), DEC);
  client.print(":");

  // Second
  if (now.second() < 10) {
    client.print("0");
  }
  client.print(now.second(), DEC);
}

void e_printUptime() {
  //startTime
}

// Sets the shift register to the corresponding byte for the zone
void water(byte zone) {
  digitalWrite(latchPin, LOW);
  shiftOut(dataPin, clockPin, MSBFIRST, zone);  
  digitalWrite(latchPin, HIGH);
}

// Helper function that sets the zone on or off. Takes an integer of the zone instead of the byte.
void waterZone(int zone) {
  currentZone = zone;
  switch (zone) {
  case 0:
    water(off);
    break;
  case 1:
    water(zone1);
    break;
  case 2:
    water(zone2);
    break;
  case 3:
    water(zone3);
    break;
  case 4:
    water(zone4);
    break;
  case 5:
    water(zone5);
    break;
  case 6:
    water(zone6);
    break;
  case 7:
    water(zone7);
    break;
  case 8:
    water(zone8);
    break;
  }
}

void printLoginMessage() {
  boolean isEvenDay = ((now.unixtime() / 86400L) % 2 == 0);
  e_printString(0); // "\nWelcome to TJ's Sprinkler.\nThe current time is:"
  e_printTime();
  client.println("");
 
  if (isEvenDay) {
    e_printString(18);
  } else {
    e_printString(19);
  }

  e_printString(1); // "Enter ? for help"
  printPrompt();
}

void printPrompt() {
  timeOfLastActivity = now.unixtime();
  client.flush();
  client.print("> ");
}

void checkConnectionTimeout() {
  if(now.unixtime() - timeOfLastActivity > connectTimeout) {
    e_printString(2); // "\n\nTimeout disconnect.\n"
    client.stop();
    clientConnected = 0;
  }
}

void getReceivedText() {
  char c;

  while (client.available() && c != 0x0d) {
    c = client.read();
    command += c;
  }

  //if CR found go look at received text and execute command
  if(c == 0x0d) {
    command = command.trim();

    switch (shellState) {
    case 0:
      parseReceivedText();
      break;
    case 1: // Days
      if (command.length() > 0) {
        workingSchedule.days = command.toInt();
      } else {
        workingSchedule.days = scheduleList[workingScheduleNumber-1].days;
      }

      e_printString(6); // "Hour "
      
      client.print("[");
      client.print(scheduleList[workingScheduleNumber-1].hour, DEC);
      client.print("]: ");
      shellState = 2;
      break;
    case 2: // Hour
      if (command.length() > 0) {
        workingSchedule.hour = command.toInt();
      } else {
        workingSchedule.hour = scheduleList[workingScheduleNumber-1].hour;
      }

      e_printString(7); // "Minute "
      client.print("[");
      client.print(scheduleList[workingScheduleNumber-1].minute, DEC);
      client.print("]: ");
      shellState = 3;
      break;
    case 3: // Minute
      if (command.length() > 0) {
        workingSchedule.minute = command.toInt();
      } else {
        workingSchedule.minute = scheduleList[workingScheduleNumber-1].minute;
      }
      e_printString(8); // "Zone (0 = off) "
      client.print("[");
      client.print(scheduleList[workingScheduleNumber-1].zone, DEC);
      client.print("]: ");
      shellState = 4;
      break;
    case 4: // Zone
      if (command.length() > 0) {
        workingSchedule.zone = command.toInt();
      } else {
        workingSchedule.zone = scheduleList[workingScheduleNumber-1].zone;
      }
      workingSchedule.deleted = 0;
      workingSchedule.enabled = 1;
      scheduleList[workingScheduleNumber-1] = workingSchedule;
      e_printString(9); // "Schedule set\n"
      shellState = 0;
      break;
    default:
      e_printString(10); // "Invalid command\n"
      shellState = 0;
      break;
    }

    command = "";
    if (shellState == 0) {
      // after completing command, print a new prompt
      printPrompt();
    }
  }

}

void parseReceivedText() {
  int firstSpace = command.indexOf(' ');

  String cmd = command.substring(0, firstSpace).trim();
  String param = command.substring(firstSpace).trim();

  if (cmd == "?") {
    e_printHelp();
  } 
  else if (cmd == "on") {
    waterZone(param.toInt());
  } 
  else if (cmd == "off") {
    waterZone(off);
  }
  else if (cmd == "mem") {
    e_printString(4); // "Bytes free: "
    client.println(availableMemory());
  }
  else if (cmd == "settime") {
    // Mon dd YYYY HH:ii:ss
    String date = param.substring(0, 11).trim();
    String time = param.substring(12).trim();

    char dateChar[date.length() + 1];
    char timeChar[time.length() + 1];

    date.toCharArray(dateChar, (date.length() + 1));
    time.toCharArray(timeChar, (time.length() + 1));

    RTC.adjust(DateTime(dateChar, timeChar));
    now = RTC.now();

    e_printString(15); // "Time set to: "
    e_printTime();
    client.println();
  }
  else if (cmd == "time") {
    e_printTime();
    client.println();
  } 
  else if (cmd == "list") {
    e_listSchedules();
  } 
  else if (cmd == "set") {
    if (param.toInt() > 0) {
      workingScheduleNumber = param.toInt();
      shellState = 1;
      e_printString(3); // "Set Schedule ";
      client.println(workingScheduleNumber);
      e_printString(5); // "Days:\n 1: Everyday\n 2: Even Days\n 3: Odd Days\nDays "
      client.print("[");
      client.print(scheduleList[workingScheduleNumber-1].days, DEC);
      client.print("]: ");
    }
  } 
  else if (cmd == "rm") {
    if (param.toInt() > 0) {
      scheduleList[param.toInt()-1].deleted = 1;
    }
    e_printString(12); // "Schedule deleted\n"
  }
  else if (cmd == "enable") {
    if (param.toInt() > 0) {
      scheduleList[param.toInt()-1].enabled = 1;
    }
    e_printString(16); // "Schedule enabled\n"
  }
  else if (cmd == "disable") {
    if (param.toInt() > 0) {
      scheduleList[param.toInt()-1].enabled = 0;
    }
    e_printString(17); // "Schedule disabled\n"
  }
  else if (cmd == "clearall") {
    initializeSchedule();
  }
  else if (cmd == "load") {
    loadSchedule();
    e_printString(14); // "Schedule loaded\n"
  }
  else if (cmd == "save") {
    saveSchedule();
    e_printString(13); // "Schedule saved\n"
  }
  else if (cmd == "exit") {
    client.stop();
    clientConnected = 0;
  }

}

void e_listSchedules() {
  client.println(" # | Enabled | Days | Time  | Zone");
  for (int i = 0; i < SCHEDULELISTSIZE; i++) {
    if (scheduleList[i].deleted == 0) {
      // #
      if (i+1 < 10) {
        client.print(" ");
      }
      client.print(i+1);
      e_printString(11); // " | "

      // Enabled
      if (scheduleList[i].enabled == 1) {
        client.print("Yes    ");
      } 
      else {
        client.print("No     ");
      }
      e_printString(11); // " | "

      // Days
      if (scheduleList[i].days == 1) {
        client.print("All ");
      } 
      else if (scheduleList[i].days == 2) {
        client.print("Even");
      } 
      else if (scheduleList[i].days == 3) {
        client.print("Odd ");
      }
      e_printString(11); // " | "

      // Time
      if (scheduleList[i].hour < 10) {
        client.print(" ");
      }
      client.print(scheduleList[i].hour, DEC);
      client.print(":");
      if (scheduleList[i].minute < 10) {
        client.print("0");
      }
      client.print(scheduleList[i].minute, DEC);
      e_printString(11); // " | "

      // Zone
      if (scheduleList[i].zone == 0) {
        client.println("Off");
      } 
      else {
        client.println(scheduleList[i].zone, DEC);
      }
    }
  }
}

void setup() {
  // Set pins to output so we can control the shift register
  pinMode(latchPin, OUTPUT);
  pinMode(clockPin, OUTPUT);
  pinMode(dataPin, OUTPUT);
  pinMode(9, OUTPUT); // LED
  digitalWrite(9, LOW);

  water(off);

  // Serial.begin(57600);
  // Serial.println("*RESET*");

  // Setup the real time clock
  Wire.begin();
  RTC.begin();
  now = RTC.now();
  lastMinute = now.minute();
  startTime = now.unixtime();

  // Setup the ethernet server
  // Ethernet.begin(mac, ip, gateway, subnet); // initialize the ethernet device
  EthernetDHCP.setHostName("Sprinkler");
  EthernetDHCP.begin(mac, 1);
  
  server.begin(); // start listening for clients

  // Load Schedule
  loadSchedule();
}

void loop() {
  // DHCP Stuff
  static DhcpState prevState = DhcpStateNone;
  DhcpState state = EthernetDHCP.poll();
  if (prevState != state) {
     if (state == DhcpStateLeased) {
       digitalWrite(9, HIGH);
     } else {
       digitalWrite(9, LOW);
     }
  }
  prevState = state;
  
  // We only need to grab the time at most every second.
  // We also need to catch when millis() rolls over back to 0 (about every 50 days)
  if (millis() > lastTimeCheck + 1000 || millis() < lastTimeCheck) {
    now = RTC.now();
    lastTimeCheck = millis();
  }


  if (lastMinute != now.minute()) {
    lastMinute = now.minute();

    // Figure out if it's an even or odd day. (use number of days since the unix epoch, not the current day of the month for a better even/odd pattern regardless of months with an odd number of days)
    boolean isEvenDay = ((now.unixtime() / 86400L) % 2 == 0);

    for (int i = 0; i < SCHEDULELISTSIZE; i++) {
      // TODO: this is a nasty looking if statement. Need to make it easier to read.
      if (scheduleList[i].deleted == 0 && // Not deleted
          scheduleList[i].enabled == 1 && // Is Enabled
          scheduleList[i].hour == now.hour() && // Is the current hour
          scheduleList[i].minute == now.minute() && // Is the current minute
          (
           (scheduleList[i].days == 1) || // This is an every-day schedule
           (scheduleList[i].days == 2 && isEvenDay) || // This is an even-day schedule, and today is an even day.
           (scheduleList[i].days == 3 && !isEvenDay) // This is an odd-day schedule, and today is an odd day.
          )
         ) {
        waterZone(scheduleList[i].zone);
      }
    }
  }

  if (server.available() && !clientConnected) { // New client connected
    clientConnected = 1;
    client = server.available();
    printLoginMessage();
  }

  // check to see if text received
  if (client.connected() && client.available()) getReceivedText();

  // check to see if connection has timed out
  if(clientConnected) checkConnectionTimeout();
}













