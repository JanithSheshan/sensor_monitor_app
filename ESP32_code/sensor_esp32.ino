#include <WiFi.h>
#include <FirebaseESP32.h>

// Firebase Configuration
#define FIREBASE_HOST "sensoread-810da-default-rtdb.firebaseio.com"
#define FIREBASE_AUTH "U4i9D7AqoFQu8uerPAMNAPBUkKCBlLwWOiT3OT7Q"
#define WIFI_SSID "Dialog 4G 253"
#define WIFI_PASSWORD "aFee4107"

// Firebase objects
FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;

unsigned long lastUpdate = 0;
const int updateInterval = 1000; // Update every 1 second
FirebaseJsonArray readingsArray; // Global array to store last 10 readings

void setup() {
  Serial.begin(115200);
  
  // Connect to WiFi
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Connecting to WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nConnected to WiFi");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());
  
  // Initialize Firebase
  config.host = FIREBASE_HOST;
  config.signer.tokens.legacy_token = FIREBASE_AUTH;
  
  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);
  
  // Set buffer sizes
  fbdo.setBSSLBufferSize(4096, 1024);
  fbdo.setResponseSize(2048);
  
  Serial.println("Firebase initialized");
  
  // Initialize readings array with some default values
  initializeReadingsArray();
}

void loop() {
  if (millis() - lastUpdate >= updateInterval) {
    sendSensorDataInFormat();
    lastUpdate = millis();
  }
}

void initializeReadingsArray() {
  // Start with 5 random readings between 0-200
  for (int i = 0; i < 5; i++) {
    float reading = random(0, 20001) / 100.0;
    readingsArray.add(reading);
  }
}

void sendSensorDataInFormat() {
  // Generate random values
  float newReading = random(0, 20001) / 100.0; // 0.0 to 200.0°C
  
  // Determine status based on temperature
  String status = "active";
  if (newReading > 80.0) {  // Alert threshold > 80 (as per your requirement)
    status = "warning";
  }
  
  // Update readings array (keep last 10 readings)
  updateReadingsArray(newReading);
  
  // Create JSON in the exact format you specified
  FirebaseJson json;
  
  // Top level fields
  json.set("sensor_id", "SENSOR_UNIT_01");
  json.set("status", status);
  json.set("readings", readingsArray); // Add the readings array
  
  // Create metadata object
  FirebaseJson metadata;
  metadata.set("battery_level", random(80, 101)); // 80-100%
  metadata.set("connection_type", "WiFi");
  
  // Add metadata to main json
  json.set("metadata", metadata);
  
  // Send to Firebase
  String path = "/sensors/SENSOR_UNIT_01";
  
  if (Firebase.setJSON(fbdo, path, json)) {
    Serial.println("✅ Data sent successfully!");
    printDataToSerial(newReading, status);
  } else {
    Serial.print("❌ Failed to send data: ");
    Serial.println(fbdo.errorReason());
    
    // Try alternative method
    Serial.println("Trying alternative method...");
    sendAlternativeFormat(newReading, status);
  }
}

void updateReadingsArray(float newReading) {
  // Add new reading to array
  readingsArray.add(newReading);
  
  // Keep only last 10 readings
  if (readingsArray.size() > 10) {
    // Create new array with last 10 readings
    FirebaseJsonArray newArray;
    
    // Calculate start index (size - 10)
    int startIndex = readingsArray.size() - 10;
    
    // Copy last 10 readings to new array
    for (int i = startIndex; i < readingsArray.size(); i++) {
      FirebaseJsonData data;
      if (readingsArray.get(data, i)) {
        newArray.add(data.to<double>());
      }
    }
    
    // Replace old array with new one
    readingsArray = newArray;
  }
}

void sendAlternativeFormat(float temperature, String status) {
  // Alternative method using separate updates
  String basePath = "/sensors/SENSOR_UNIT_01";
  
  // Send sensor_id
  Firebase.setString(fbdo, basePath + "/sensor_id", "SENSOR_UNIT_01");
  
  // Send status
  Firebase.setString(fbdo, basePath + "/status", status);
  
  // Send readings array
  Firebase.setArray(fbdo, basePath + "/readings", readingsArray);
  
  // Send metadata
  FirebaseJson metadata;
  metadata.set("battery_level", random(80, 101));
  metadata.set("connection_type", "WiFi");
  Firebase.setJSON(fbdo, basePath + "/metadata", metadata);
  
  Serial.println("✅ Data sent via alternative method");
}

void printDataToSerial(float newReading, String status) {
  Serial.println("📊 Sent Data Format:");
  Serial.println("{");
  Serial.print("  \"sensor_id\": \"SENSOR_UNIT_01\"");
  Serial.println("\",");
  
  Serial.print("  \"readings\": [");
  for (int i = 0; i < readingsArray.size(); i++) {
    FirebaseJsonData data;
    if (readingsArray.get(data, i)) {
      Serial.print(data.to<double>(), 1);
      if (i < readingsArray.size() - 1) Serial.print(", ");
    }
  }
  Serial.println("],");
  
  Serial.println("  \"metadata\": {");
  Serial.print("    \"battery_level\": ");
  Serial.print(random(80, 101));
  Serial.println(",");
  Serial.println("    \"connection_type\": \"WiFi\"");
  Serial.println("  }");
  Serial.println("}");
  Serial.print("New Reading: ");
  Serial.print(newReading);
  Serial.print("°C");
  Serial.print(" | Array Size: ");
  Serial.println(readingsArray.size());
  Serial.println("--------------------------------");
}

// Simple debug function to check connection
void testFirebaseConnection() {
  String testPath = "/test_connection";
  if (Firebase.setString(fbdo, testPath, "Hello from ESP32")) {
    Serial.println("Firebase connection test: PASSED");
  } else {
    Serial.print("Firebase connection test: FAILED - ");
    Serial.println(fbdo.errorReason());
  }
}
