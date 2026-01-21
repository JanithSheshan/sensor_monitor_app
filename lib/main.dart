import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:share_plus/share_plus.dart';

void main() async {
  // Initialize Flutter binding for Firebase
  WidgetsFlutterBinding.ensureInitialized();

  // Configure Firebase with project credentials
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "AIzaSyAq9d_2nA4MlD8m0qW6S5Q8T8h8d2K9j3M",
      appId: "1:123456789012:android:abcdef123456",
      messagingSenderId: "123456789012",
      projectId: "sensoread-810da",
      databaseURL: "https://sensoread-810da-default-rtdb.firebaseio.com",
    ),
  );

  // Start the app
  runApp(const SensorMonitorApp());
}

// Data model class for sensor information
class SensorData {
  final String sensorId;
  final List<double> readings;
  final int batteryLevel;
  final String connectionType;
  final DateTime timestamp;

  SensorData({
    required this.sensorId,
    required this.readings,
    required this.batteryLevel,
    required this.connectionType,
    required this.timestamp,
  });

  // Factory constructor to create SensorData from Firebase map
  factory SensorData.fromMap(Map<dynamic, dynamic> data) {
    List<double> readingsList = [];

    // Parse temperature readings from list
    if (data['readings'] is List) {
      for (var item in data['readings']) {
        if (item != null) {
          readingsList.add(double.parse(item.toString()));
        }
      }
    }

    // Extract battery level from metadata
    int battery = 0;
    if (data['metadata'] != null &&
        data['metadata'] is Map &&
        data['metadata']['battery_level'] != null) {
      battery = int.parse(data['metadata']['battery_level'].toString());
    }

    // Extract connection type from metadata
    String connection = 'Unknown';
    if (data['metadata'] != null &&
        data['metadata'] is Map &&
        data['metadata']['connection_type'] != null) {
      connection = data['metadata']['connection_type'].toString();
    }

    return SensorData(
      sensorId: data['sensor_id']?.toString() ?? 'Unknown',
      readings: readingsList,
      batteryLevel: battery,
      connectionType: connection,
      timestamp: DateTime.now(),
    );
  }

  // Check if current reading is in warning range (190-200°C or 20-10°C)
  bool get isWarning => readings.isNotEmpty &&
      (readings.last > 190 || readings.last < 20);

  // Check if current reading is in critical range (>200°C or <10°C)
  bool get isCritical => readings.isNotEmpty &&
      (readings.last > 200 || readings.last < 10);

  // Get last 10 readings for chart display
  List<double> get lastTenReadings {
    final length = readings.length;
    if (length <= 10) return readings;
    return readings.sublist(length - 10);
  }

  // Convert last 10 readings to chart data points
  List<FlSpot> get chartSpots {
    List<FlSpot> spots = [];
    final lastTen = lastTenReadings;

    for (int i = 0; i < lastTen.length; i++) {
      spots.add(FlSpot(i.toDouble(), lastTen[i]));
    }
    return spots;
  }

  // Generate CSV string from sensor data for export
  String generateCSV() {
    List<List<dynamic>> csvData = [
      ['Timestamp', 'Reading (°C)', 'Sensor ID', 'Status', 'Battery Level', 'Connection Type']
    ];

    // Create CSV rows for each reading
    for (int i = 0; i < readings.length; i++) {
      final reading = readings[i];
      final isWarning = reading > 190 || reading < 20;
      final timestamp = DateTime.now().subtract(Duration(seconds: (readings.length - i) * 5));
      csvData.add([
        timestamp.toIso8601String(),
        reading.toStringAsFixed(2),
        sensorId,
        isWarning ? 'WARNING' : 'NORMAL',
        batteryLevel,
        connectionType
      ]);
    }

    return const ListToCsvConverter().convert(csvData);
  }

  // Calculate average temperature from all readings
  double get averageTemperature {
    if (readings.isEmpty) return 0;
    return readings.reduce((a, b) => a + b) / readings.length;
  }

  // Find minimum temperature from all readings
  double get minTemperature {
    if (readings.isEmpty) return 0;
    return readings.reduce((a, b) => a < b ? a : b);
  }

  // Find maximum temperature from all readings
  double get maxTemperature {
    if (readings.isEmpty) return 0;
    return readings.reduce((a, b) => a > b ? a : b);
  }
}

// Main app widget
class SensorMonitorApp extends StatelessWidget {
  const SensorMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SensorPro Analytics',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Inter',
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: Colors.grey.shade200,
              width: 1,
            ),
          ),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B82F6),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Inter',
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      home: const SensorScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// Main screen widget that displays sensor data
class SensorScreen extends StatefulWidget {
  const SensorScreen({super.key});

  @override
  State<SensorScreen> createState() => _SensorScreenState();
}

class _SensorScreenState extends State<SensorScreen> {
  // Firebase database reference
  late DatabaseReference _sensorRef;

  // Sensor data state
  SensorData? _sensorData;
  bool _isLoading = true;
  bool _hasError = false;
  DateTime? _lastUpdateTime;

  // Timer for checking updates
  Timer? _updateCheckTimer;
  bool _isUpdating = false;

  // Firebase subscription
  StreamSubscription<DatabaseEvent>? _databaseSubscription;

  // Chart data
  List<double> _chartData = [];

  // Page controller for tab navigation
  final PageController _pageController = PageController();
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    // Setup Firebase listener when widget initializes
    _setupFirebaseListener();
    // Start timer to check for updates
    _startUpdateCheckTimer();
  }

  @override
  void dispose() {
    // Clean up resources
    _updateCheckTimer?.cancel();
    _databaseSubscription?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  // Start timer to check if sensor is still sending updates
  void _startUpdateCheckTimer() {
    _updateCheckTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_lastUpdateTime != null) {
        final now = DateTime.now();
        final difference = now.difference(_lastUpdateTime!);

        // If no update for more than 5 seconds, mark as idle
        if (difference.inSeconds > 5) {
          if (_isUpdating && mounted) {
            setState(() {
              _isUpdating = false;
            });
          }
        } else {
          // If update within 5 seconds, mark as live
          if (!_isUpdating && mounted) {
            setState(() {
              _isUpdating = true;
            });
          }
        }
      }
    });
  }

  // Export sensor data to CSV file and share it
  Future<void> _exportToCSV() async {
    if (_sensorData == null) return;

    try {
      // Generate CSV content
      final csvContent = _sensorData!.generateCSV();
      final directory = await getTemporaryDirectory();
      final fileName = 'sensor_data_${_sensorData!.sensorId}_${DateTime.now().millisecondsSinceEpoch}.csv';
      final file = File('${directory.path}/$fileName');
      await file.writeAsString(csvContent);

      // Share the CSV file
      final result = await Share.shareXFiles([XFile(file.path)],
          text: 'Sensor Data Export - ${_sensorData!.sensorId}',
          subject: 'Sensor Data CSV Export'
      );

      // Show success message
      if (result.status == ShareResultStatus.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('CSV exported successfully!'),
            backgroundColor: Theme.of(context).colorScheme.primary,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    } catch (e) {
      // Show error message if export fails
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to export CSV: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    }
  }

  // Setup Firebase realtime database listener
  void _setupFirebaseListener() {
    try {
      // Reference to specific sensor node
      _sensorRef = FirebaseDatabase.instance.ref('sensors/SENSOR_UNIT_01');

      // Listen for data changes
      _databaseSubscription = _sensorRef.onValue.listen((event) {
        final data = event.snapshot.value;

        if (data != null && data is Map) {
          // Track previous reading count to detect new readings
          final previousReadingCount = _sensorData?.readings.length ?? 0;
          final newData = SensorData.fromMap(Map<String, dynamic>.from(data));
          final currentReadingCount = newData.readings.length;

          // Update state with new data
          setState(() {
            _sensorData = newData;
            _lastUpdateTime = DateTime.now();
            _isLoading = false;
            _hasError = false;
            _chartData = newData.lastTenReadings;

            // Mark as updating if new readings arrived
            if (currentReadingCount > previousReadingCount) {
              _isUpdating = true;
            }
          });
        }
      }, onError: (error) {
        // Handle Firebase errors
        setState(() {
          _hasError = true;
          _isLoading = false;
          _isUpdating = false;
        });
      });
    } catch (e) {
      // Handle initialization errors
      setState(() {
        _hasError = true;
        _isLoading = false;
        _isUpdating = false;
      });
    }
  }

  // Build update status indicator widget
  Widget _buildUpdateStatus(bool isUpdating) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isUpdating
            ? Colors.green.withOpacity(0.1)
            : Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isUpdating ? Colors.green : Colors.orange,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status indicator dot
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isUpdating ? Colors.green : Colors.orange,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            isUpdating ? 'LIVE' : 'IDLE',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isUpdating ? Colors.green : Colors.orange,
            ),
          ),
        ],
      ),
    );
  }

  // Build battery level indicator widget
  Widget _buildBatteryIndicator(int level) {
    // Determine color based on battery level
    Color batteryColor;
    if (level > 70) {
      batteryColor = Colors.green;
    } else if (level > 30) {
      batteryColor = Colors.orange;
    } else {
      batteryColor = Colors.red;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: batteryColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(
            Icons.battery_full,
            color: batteryColor,
            size: 16,
          ),
          const SizedBox(width: 4),
          Text(
            '$level%',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: batteryColor,
            ),
          ),
        ],
      ),
    );
  }

  // Build connection type indicator widget
  Widget _buildConnectionIndicator(String type) {
    IconData icon;
    Color color;

    // Set icon and color based on connection type
    switch (type.toLowerCase()) {
      case 'wifi':
        icon = Icons.wifi;
        color = Colors.blue;
        break;
      case 'ethernet':
        icon = Icons.settings_ethernet;
        color = Colors.green;
        break;
      default:
        icon = Icons.signal_cellular_alt;
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            type.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // Build main temperature card widget
  Widget _buildTemperatureCard() {
    if (_sensorData == null) return Container();

    final isWarning = _sensorData!.isWarning;
    final isCritical = _sensorData!.isCritical;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Sensor ID and status row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SENSOR UNIT',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _sensorData!.sensorId,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                _buildUpdateStatus(_isUpdating),
              ],
            ),
            const SizedBox(height: 20),

            // Warning/Critical alert
            if (isCritical)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.red),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'CRITICAL: Temperature out of safe range',
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else if (isWarning)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.orange),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'WARNING: Temperature approaching limits',
                        style: TextStyle(
                          color: Colors.orange,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            if (isWarning || isCritical) const SizedBox(height: 20),

            // Current temperature display
            Center(
              child: Column(
                children: [
                  Text(
                    'Current Temperature',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _sensorData!.readings.isNotEmpty
                        ? '${_sensorData!.readings.last.toStringAsFixed(2)}°C'
                        : '--',
                    style: Theme.of(context).textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: isCritical
                          ? Colors.red
                          : isWarning
                          ? Colors.orange
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Battery and connection indicators
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildBatteryIndicator(_sensorData!.batteryLevel),
                _buildConnectionIndicator(_sensorData!.connectionType),
              ],
            ),
            const SizedBox(height: 16),

            Divider(
              color: Theme.of(context).dividerColor.withOpacity(0.3),
              height: 1,
            ),
            const SizedBox(height: 16),

            // Last update time
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Last updated',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
                Text(
                  '${_sensorData!.timestamp.hour.toString().padLeft(2, '0')}:${_sensorData!.timestamp.minute.toString().padLeft(2, '0')}:${_sensorData!.timestamp.second.toString().padLeft(2, '0')}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Build temperature trend chart widget
  Widget _buildAnalyticsChart() {
    if (_chartData.isEmpty || _sensorData == null) {
      return Container(
        height: 300,
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.show_chart_rounded,
                size: 48,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
              ),
              const SizedBox(height: 16),
              Text(
                'Waiting for data...',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final spots = _sensorData!.chartSpots;
    final maxY = _chartData.isNotEmpty ? _chartData.reduce((a, b) => a > b ? a : b) : 100;
    final minY = _chartData.isNotEmpty ? _chartData.reduce((a, b) => a < b ? a : b) : 0;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Chart header with export button
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Temperature Trend',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  onPressed: _exportToCSV,
                  icon: Icon(
                    Icons.download_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  tooltip: 'Export Data',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Last 10 readings',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 20),

            // Line chart
            SizedBox(
              height: 250,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: 20,
                    getDrawingHorizontalLine: (value) {
                      return FlLine(
                        color: Theme.of(context).dividerColor.withOpacity(0.3),
                        strokeWidth: 1,
                      );
                    },
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        interval: 1,
                        getTitlesWidget: (value, meta) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '${value.toInt() + 1}',
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 20,
                        reservedSize: 40,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            '${value.toInt()}°C',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  minX: 0,
                  maxX: spots.length > 0 ? spots.length.toDouble() - 1 : 9,
                  minY: (minY - 10).clamp(0, double.infinity).toDouble(),
                  maxY: (maxY + 10).clamp(0, double.infinity).toDouble(),
                  lineBarsData: [
                    // Main temperature line
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: Theme.of(context).colorScheme.primary,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, barData, index) {
                          return FlDotCirclePainter(
                            radius: 4,
                            color: Theme.of(context).colorScheme.primary,
                            strokeWidth: 2,
                            strokeColor: Theme.of(context).colorScheme.surface,
                          );
                        },
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Theme.of(context).colorScheme.primary.withOpacity(0.3),
                            Theme.of(context).colorScheme.primary.withOpacity(0.05),
                          ],
                        ),
                      ),
                    ),
                    // Upper warning line (190°C)
                    LineChartBarData(
                      spots: [
                        FlSpot(0, 190),
                        FlSpot(spots.length > 0 ? spots.length.toDouble() - 1 : 9, 190),
                      ],
                      color: Colors.red.withOpacity(0.3),
                      barWidth: 2,
                      dashArray: [5, 5],
                      isCurved: false,
                      dotData: const FlDotData(show: false),
                    ),
                    // Lower warning line (20°C)
                    LineChartBarData(
                      spots: [
                        FlSpot(0, 20),
                        FlSpot(spots.length > 0 ? spots.length.toDouble() - 1 : 9, 20),
                      ],
                      color: Colors.red.withOpacity(0.3),
                      barWidth: 2,
                      dashArray: [5, 5],
                      isCurved: false,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    enabled: true,
                    touchTooltipData: LineTouchTooltipData(
                      tooltipBgColor: Theme.of(context).colorScheme.surface,
                      tooltipRoundedRadius: 8,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          return LineTooltipItem(
                            '${spot.y.toStringAsFixed(1)}°C\nReading #${spot.x.toInt() + 1}',
                            TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          );
                        }).toList();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Build analytics grid with metrics
  Widget _buildAnalyticsGrid() {
    if (_sensorData == null) return Container();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Performance Analytics',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 20),

            // Responsive grid layout
            LayoutBuilder(
              builder: (context, constraints) {
                // Calculate card dimensions based on available width
                final cardWidth = (constraints.maxWidth - 48) / 2;
                final cardHeight = cardWidth * 0.85;

                return GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: cardWidth / cardHeight,
                  children: [
                    _buildAnalyticCard(
                      'Average',
                      '${_sensorData!.averageTemperature.toStringAsFixed(1)}°C',
                      Icons.thermostat_rounded,
                      Colors.blue,
                    ),
                    _buildAnalyticCard(
                      'Maximum',
                      '${_sensorData!.maxTemperature.toStringAsFixed(1)}°C',
                      Icons.trending_up_rounded,
                      Colors.orange,
                    ),
                    _buildAnalyticCard(
                      'Minimum',
                      '${_sensorData!.minTemperature.toStringAsFixed(1)}°C',
                      Icons.trending_down_rounded,
                      Colors.green,
                    ),
                    _buildAnalyticCard(
                      'Readings',
                      '${_sensorData!.readings.length}',
                      Icons.data_array_rounded,
                      Colors.purple,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // Build individual analytic card widget
  Widget _buildAnalyticCard(String title, String value, IconData icon, Color color) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withOpacity(0.1),
        border: Border.all(
          color: color.withOpacity(0.2),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Icon container
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 18),
          ),

          // Value and title
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Build tab navigation bar
  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildTabButton('Overview', 0),
          ),
          Expanded(
            child: _buildTabButton('Analytics', 1),
          ),
          Expanded(
            child: _buildTabButton('History', 2),
          ),
        ],
      ),
    );
  }

  // Build individual tab button
  Widget _buildTabButton(String text, int index) {
    final isSelected = _selectedTab == index;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedTab = index;
        });
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isSelected
                  ? Theme.of(context).colorScheme.onPrimary
                  : Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
        ),
      ),
    );
  }

  // Build overview page with all main widgets
  Widget _buildOverviewPage() {
    return SingleChildScrollView(
      child: Column(
        children: [
          _buildTemperatureCard(),
          _buildAnalyticsChart(),
          _buildAnalyticsGrid(),
          const SizedBox(height: 16), // Extra padding at bottom
        ],
      ),
    );
  }

  // Build analytics page (placeholder)
  Widget _buildAnalyticsPage() {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.analytics_rounded,
                size: 64,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
              ),
              const SizedBox(height: 16),
              Text(
                'Advanced Analytics',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Detailed analysis coming soon',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Build history page with reading list
  Widget _buildHistoryPage() {
    if (_sensorData == null || _sensorData!.readings.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.history_rounded,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                ),
                const SizedBox(height: 16),
                Text(
                  'No History Data',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Sensor readings will appear here',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // List of historical readings
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _sensorData!.readings.length,
      itemBuilder: (context, index) {
        // Show most recent readings first
        final reversedIndex = _sensorData!.readings.length - 1 - index;
        final reading = _sensorData!.readings[reversedIndex];
        final isWarning = reading > 190 || reading < 20;
        final isCritical = reading > 200 || reading < 10;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).dividerColor.withOpacity(0.2),
            ),
          ),
          child: ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isCritical
                    ? Colors.red.withOpacity(0.1)
                    : isWarning
                    ? Colors.orange.withOpacity(0.1)
                    : Theme.of(context).colorScheme.primary.withOpacity(0.1),
              ),
              child: Icon(
                isCritical
                    ? Icons.warning_amber_rounded
                    : isWarning
                    ? Icons.warning_rounded
                    : Icons.thermostat_rounded,
                color: isCritical
                    ? Colors.red
                    : isWarning
                    ? Colors.orange
                    : Theme.of(context).colorScheme.primary,
                size: 20,
              ),
            ),
            title: Text(
              '${reading.toStringAsFixed(2)}°C',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isCritical
                    ? Colors.red
                    : isWarning
                    ? Colors.orange
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
            subtitle: Text(
              'Reading ${reversedIndex + 1}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: isCritical
                    ? Colors.red.withOpacity(0.1)
                    : isWarning
                    ? Colors.orange.withOpacity(0.1)
                    : Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isCritical
                      ? Colors.red
                      : isWarning
                      ? Colors.orange
                      : Colors.green,
                  width: 1,
                ),
              ),
              child: Text(
                isCritical ? 'CRITICAL' : isWarning ? 'WARNING' : 'NORMAL',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: isCritical
                      ? Colors.red
                      : isWarning
                      ? Colors.orange
                      : Colors.green,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'SensorPro',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        centerTitle: false,
        actions: [
          // Refresh button
          IconButton(
            icon: Icon(
              Icons.refresh_rounded,
              color: _isUpdating
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
            ),
            onPressed: () {
              _databaseSubscription?.cancel();
              _setupFirebaseListener();
            },
            tooltip: 'Refresh Connection',
          ),
          // Export button
          IconButton(
            icon: const Icon(Icons.download_rounded),
            onPressed: _exportToCSV,
            tooltip: 'Export Data',
          ),
        ],
        elevation: 0,
        backgroundColor: Theme.of(context).colorScheme.surface,
        scrolledUnderElevation: 2,
      ),

      // Main body with loading/error/content states
      body: _isLoading
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Connecting to Sensor...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Establishing Firebase connection',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ],
        ),
      )
          : _hasError
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Error icon
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withOpacity(0.1),
                ),
                child: Icon(
                  Icons.error_outline_rounded,
                  size: 48,
                  color: Colors.red,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Connection Error',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Unable to connect to Firebase database. Please check your configuration and network connection.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
              const SizedBox(height: 32),
              // Retry button
              ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _hasError = false;
                  });
                  _setupFirebaseListener();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry Connection'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      )
          : Column(
        children: [
          _buildTabBar(),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (index) {
                setState(() {
                  _selectedTab = index;
                });
              },
              children: [
                _buildOverviewPage(),
                _buildAnalyticsPage(),
                _buildHistoryPage(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}