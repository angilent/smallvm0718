/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// Copyright 2018 John Maloney, Bernat Romagosa, and Jens Mönig

// netPrims.cpp - MicroBlocks network primitives
// Bernat Romagosa, August 2018

#include "mem.h"

#ifdef ESP8266

#include <ESP8266WiFi.h>
#include "interp.h" // must be included *after* ESP8266WiFi.h

// Buffer for Mozilla Web of Things JSON definition
#define WEBTHING_BUF_SIZE 1024
static char webThingBuffer[WEBTHING_BUF_SIZE];

#define JSON_HEADER "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
static char connecting = false;
static uint32 initTime;

WiFiServer server(80);

void primWifiConnect(OBJ *args) {
  // don't cancel ongoing connection attempts
  if (!connecting) {
    WiFi.disconnect();
    WiFi.mode(WIFI_STA);
    connecting = true;
    initTime = millisecs();
    char *essid = obj2str(args[0]);
    char *psk = obj2str(args[1]);
    WiFi.begin(essid, psk);
  }
}

void initWebServer() {
  server.stop();
  server.begin();
}

void notFoundResponse(WiFiClient client) {
  client.flush();
  client.print(
    "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n"
    "{\"error\":\"Resource not found\"}"
  );
}

void webServerLoop() {
  WiFiClient client = server.available();
  if (!client) {
    return;
  }
  while (!client.available()) {
    delay(1);
  }

  char request[100];
  char url[100];
  char *part;
  client.readStringUntil('\r').toCharArray(request, 100);
  // request looks like "GET /some/url HTTP/1.1"
  // The URL lives between the two only spaces in the request
  strcpy(url, strtok(strchr(request, ' '), " "));

  // We tokenize the URL and walk the tree
  part = strtok(url,"/");
  if (part != NULL && strcmp(part, "things") == 0) {
    // We're at /things
    part = strtok(NULL,"/");
    if (part != NULL && strcmp(part, "ub") == 0) {
      // We're at /things/ub
      part = strtok(NULL, "/");
      if (part != NULL && strcmp(part, "properties") == 0) {
        // We're at /things/ub/properties
        // next token contains the property name
        char* varName = strtok(NULL,"/");
        if (varName != NULL) {
          OBJ variable;
          // We now look for the varID of this var in our records
          for (int varID = 0; varID < MAX_VARS; varID++) {
            int *rec = varNameRecordFor(varID);
            if (rec) {
              char *eachVarName = (char *) (rec + 2);
              if (strcmp(eachVarName, varName) == 0) {
                variable = vars[varID];
                break;
              }
            }
          }
          char s[100];
          switch (objClass(variable)) {
            case StringClass:
              sprintf(s, "%s {\"%s\": \"%s\"}", JSON_HEADER, varName, obj2str(variable));
              break;
            case IntegerClass:
              sprintf(s, "%s {\"%s\": %i}", JSON_HEADER, varName, obj2int(variable));
              break;
            case BooleanClass:
              sprintf(s, "%s {\"%s\": %s}", JSON_HEADER, varName, (trueObj == variable ? "true" : "false"));;
              break;
            default:
              sprintf(s, "%s {\"%s\": \"unknown variable type\"}", JSON_HEADER, varName);;
              break;
          }
          client.flush();
          client.print(s);
        } else {
          notFoundResponse(client);
        }
      } else {
        // Full URL is /things/ub
        client.flush();
        client.print(webThingBuffer);
      }
    } else {
      notFoundResponse(client);
    }
  } else {
    notFoundResponse(client);
  }
}

int wifiStatus() {
  //  WL_IDLE_STATUS      = 0
  //  WL_CONNECTED        = 3
  //  WL_CONNECT_FAILED   = 4
  //  WL_CONNECTION_LOST  = 5
  //  WL_DISCONNECTED     = 6
  int status = WiFi.status();
  if (status == 3 && WiFi.localIP()[0] != 0 && millisecs() > initTime + 250) {
    // Got an IP. We're online. We wait at least a quarter second, otherwise
    // we may have read an old state
    connecting = false;
    initWebServer();
  } else if (status != 3 && millisecs() > initTime + 10000) {
    // We time out after 10s
    WiFi.disconnect();
    status = WL_DISCONNECTED;
    connecting = false;
    fail(noNetwork);
  } else {
    // Still waiting
    status = WL_IDLE_STATUS;
  }
  return status;
}

OBJ primGetIP(OBJ *args) {
  IPAddress ip = WiFi.localIP();
  char ipString[17];
  sprintf(ipString, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
  return newStringFromBytes((uint8*) ipString, strlen(ipString));
}

OBJ primMakeWebThing(int argCount, OBJ *args) {
  char* thingName = obj2str(args[0]);
  int bytesWritten = sprintf(
    webThingBuffer,
    "%s"
    "{\"name\":\"%s\","
    "\"@type\":\"MicroBlocks\","
    "\"description\":\"%s\","
    "\"href\":\"/things/ub\","
    "\"properties\":{",
    JSON_HEADER,
    thingName,
    thingName
  );
  for (int i = 1; i < argCount; i += 3) {
    char* propertyType = obj2str(args[i]);
    char* propertyLabel = obj2str(args[i+1]);
    char* propertyVar = obj2str(args[i+2]);
    bytesWritten += sprintf(
      webThingBuffer + bytesWritten,
      "\"%s\":"
        "{\"type\":\"%s\","
         "\"label\":\"%s\","
         "\"href\":\"/things/ub/properties/%s\""
        "},",
      propertyVar,
      propertyType,
      propertyLabel,
      propertyVar
    );
  }
  if (argCount > 2) {
    // we subtract one position to overwrite the last comma
    bytesWritten --;
  }
  sprintf(webThingBuffer + bytesWritten, "}}\0");
}

#else

#include "interp.h"

void primWifiConnect(OBJ *args) {
  fail(noNetwork);
}

int wifiStatus() {
  return 4; // WL_CONNECT_FAILED = 4
}

OBJ primGetIP(OBJ *args) {
  fail(noNetwork);
  return int2obj(0);
}

OBJ primMakeWebThing(int argCount, OBJ *args) {
  fail(noNetwork);
}

#endif
