import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  // Getter de la base de datos requerido por las vistas
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('ventas_hob.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
      onUpgrade: _onUpgradeDB, // Protege los datos al actualizar el APK
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE clientes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        codigo TEXT,
        nombre TEXT,
        telefono TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE productos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        codigo TEXT,
        nombre TEXT,
        precio REAL
      )
    ''');

    await db.execute('''
      CREATE TABLE pedidos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        numero_pedido TEXT,
        cliente TEXT,
        productos_json TEXT,
        total REAL,
        fecha TEXT,
        semana TEXT,
        gestionado INTEGER,
        incidencia TEXT,
        total_real REAL
      )
    ''');
  }

  // Método de migración seguro para futuras actualizaciones sin perder datos
  Future _onUpgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Futuras actualizaciones de columnas o tablas van aquí
    }
  }

  // Métodos de sincronización desde CSV
  Future<void> sincronizarClientesDesdeCSV(String csvData) async {
    final db = await instance.database;
    List<String> lineas = csvData.split('\n');
    await db.transaction((txn) async {
      await txn.delete('clientes');
      for (var i = 1; i < lineas.length; i++) {
        var linea = lineas[i].trim();
        if (linea.isEmpty) continue;
        var cols = linea.split(',');
        if (cols.length >= 3) {
          await txn.insert('clientes', {
            'codigo': cols[0].trim(),
            'nombre': cols[1].trim(),
            'telefono': cols[2].trim(),
          });
        }
      }
    });
  }

  Future<void> sincronizarProductosDesdeCSV(String csvData) async {
    final db = await instance.database;
    List<String> lineas = csvData.split('\n');
    await db.transaction((txn) async {
      await txn.delete('productos');
      for (var i = 1; i < lineas.length; i++) {
        var linea = lineas[i].trim();
        if (linea.isEmpty) continue;
        var cols = linea.split(',');
        if (cols.length >= 3) {
          await txn.insert('productos', {
            'codigo': cols[0].trim(),
            'nombre': cols[1].trim(),
            'precio': double.tryParse(cols[2].trim()) ?? 0.0,
          });
        }
      }
    });
  }

  /// Genera, procesa y guarda el reporte en la carpeta Descargas de Android
  static Future<String?> generarYGuardarReporteGeneral({
    required int pedidoInicial,
    required int pedidoFinal,
    required List<Map<String, dynamic>> listaProductosVendidos,
    required String nombreArchivo,
  }) async {
    try {
      listaProductosVendidos.sort((a, b) {
        double totalA = (a['valorTotal'] ?? 0.0).toDouble();
        double totalB = (b['valorTotal'] ?? 0.0).toDouble();
        return totalB.compareTo(totalA);
      });

      final pdf = pw.Document();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(32),
          build: (pw.Context context) {
            return [
              pw.Header(
                level: 0,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Reporte General de Pedidos y Ventas',
                        style: pw.TextStyle(
                            fontSize: 18, fontWeight: pw.FontWeight.bold)),
                    pw.Text('Fecha: ${DateTime.now().toLocal().toString().split(' ')[0]}',
                        style: const pw.TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Container(
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey400),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                  children: [
                    pw.Text('Pedido Inicial: $pedidoInicial',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                    pw.Text('Pedido Final: $pedidoFinal',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  ],
                ),
              ),
              pw.SizedBox(height: 20),
              pw.Text('Productos Vendidos (Ordenados por Valor Total)',
                  style: pw.TextStyle(
                      fontSize: 14, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              pw.Table.fromTextArray(
                context: context,
                headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
                headerHeight: 25,
                cellHeight: 30,
                cellAlignment: pw.Alignment.centerLeft,
                headerStyle: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 10),
                cellStyle: const pw.TextStyle(fontSize: 10),
                headers: ['Producto', 'Cantidad Total', 'Valor Total'],
                data: listaProductosVendidos.map((producto) {
                  return [
                    producto['nombre'] ?? 'Sin nombre',
                    producto['cantidad'].toString(),
                    'L ${(producto['valorTotal'] ?? 0.0).toStringAsFixed(2)}',
                  ];
                }).toList(),
              ),
            ];
          },
        ),
      );

      final Uint8List pdfBytes = await pdf.save();
      var status = await Permission.storage.request();

      if (status.isGranted || Platform.isAndroid) {
        Directory? directorio;

        if (Platform.isAndroid) {
          directorio = Directory('/storage/emulated/0/Download');
          if (!await directorio.exists()) {
            directorio = await getExternalStorageDirectory();
          }
        } else {
          directorio = await getApplicationDocumentsDirectory();
        }

        final rutaCompleta = '${directorio?.path}/$nombreArchivo';
        final archivo = File(rutaCompleta);
        await archivo.writeAsBytes(pdfBytes);

        return rutaCompleta;
      } else {
        throw Exception('Permisos de almacenamiento denegados.');
      }
    } catch (e) {
      print('Error al generar o guardar el PDF: $e');
      return null;
    }
  }
}
