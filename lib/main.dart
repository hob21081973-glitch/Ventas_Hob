import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'dart:typed_data'; // <-- Necesario para Uint8List
import 'package:file_picker/file_picker.dart'; // <-- Necesario para FilePicker.platform.saveFile

// URLs de Google Sheets
const String urlClientesCSV = 'https://docs.google.com/spreadsheets/d/e/2PACX-1vTmtKhEE5ziDtm_BQdAeOy8c-Z6H6_GbyKcPOvtdjfKtXgxYObBUB-PlK0ldsiwrW78aabDzei-R2Cd/pub?gid=0&single=true&output=csv';
const String urlProductosCSV = 'https://docs.google.com/spreadsheets/d/e/2PACX-1vTmtKhEE5ziDtm_BQdAeOy8c-Z6H6_GbyKcPOvtdjfKtXgxYObBUB-PlK0ldsiwrW78aabDzei-R2Cd/pub?gid=1903712481&single=true&output=csv';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AppVentasHob());
}

class AppVentasHob extends StatelessWidget {
  const AppVentasHob({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'APP VENTAS HOB',
      theme: ThemeData(primarySwatch: Colors.indigo),
      home: const MenuPrincipal(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ==========================================
// BASE DE DATOS LOCAL (SQLITE)
// ==========================================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('ventas_app.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = '$dbPath/$filePath';

    return await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE clientes (
            codigo TEXT PRIMARY KEY,
            nombre TEXT,
            telefono TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE productos (
            codigo TEXT PRIMARY KEY,
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
            semana TEXT DEFAULT 'Sin Asignar',
            gestionado INTEGER DEFAULT 0,
            incidencia TEXT DEFAULT '',
            total_real REAL DEFAULT 0.0
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute("ALTER TABLE pedidos ADD COLUMN semana TEXT DEFAULT 'Sin Asignar'");
        }
        if (oldVersion < 3) {
          await db.execute("ALTER TABLE pedidos ADD COLUMN gestionado INTEGER DEFAULT 0");
          await db.execute("ALTER TABLE pedidos ADD COLUMN incidencia TEXT DEFAULT ''");
          await db.execute("ALTER TABLE pedidos ADD COLUMN total_real REAL DEFAULT 0.0");
        }
      },
    );
  }

  Future<void> sincronizarClientesDesdeCSV(String csvData) async {
    final db = await instance.database;
    List<String> lineas = csvData.split('\n');
    await db.transaction((txn) async {
      await txn.delete('clientes');
      for (int i = 1; i < lineas.length; i++) {
        var linea = lineas[i].trim();
        if (linea.isEmpty) continue;
        List<String> cols = linea.split(',');
        if (cols.length >= 3) {
          await txn.insert('clientes', {
            'codigo': cols[0].replaceAll('"', '').trim(),
            'nombre': cols[1].replaceAll('"', '').trim(),
            'telefono': cols[2].replaceAll('"', '').trim(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  Future<void> sincronizarProductosDesdeCSV(String csvData) async {
    final db = await instance.database;
    List<String> lineas = csvData.split('\n');
    await db.transaction((txn) async {
      await txn.delete('productos');
      for (int i = 1; i < lineas.length; i++) {
        var linea = lineas[i].trim();
        if (linea.isEmpty) continue;
        List<String> cols = linea.split(',');
        if (cols.length >= 3) {
          String precioStr = cols[2].replaceAll('L', '').replaceAll(',', '').replaceAll('"', '').trim();
          double precio = double.tryParse(precioStr) ?? 0.0;
          await txn.insert('productos', {
            'codigo': cols[0].replaceAll('"', '').trim(),
            'nombre': cols[1].replaceAll('"', '').trim(),
            'precio': precio,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }
}

// Utilidad para guardar PDFs estrictamente en la carpeta Descargas del dispositivo
Future<void> guardarPdfEnDescargas(pw.Document pdf, String nombreArchivo) async {
  Directory? directorio;
  if (Platform.isAndroid) {
    directorio = Directory('/storage/emulated/0/Download');
    if (!await directorio.exists()) {
      try {
        await directorio.create(recursive: true);
      } catch (_) {
        directorio = await getExternalStorageDirectory();
      }
    }
  } else {
    directorio = await getDownloadsDirectory();
  }
  
  directorio ??= await getApplicationDocumentsDirectory();
  
  final file = File('${directorio.path}/$nombreArchivo');
  await file.writeAsBytes(await pdf.save());
}

// ==========================================
// MENÚ PRINCIPAL CON DESPLAZAMIENTO (SWIPE)
// ==========================================
class MenuPrincipal extends StatefulWidget {
  const MenuPrincipal({super.key});

  @override
  State<MenuPrincipal> createState() => MenuPrincipalState();
}

class MenuPrincipalState extends State<MenuPrincipal> {
  final PageController pageController = PageController();
  int _indiceActual = 0;
  
  int? editandoPedidoId;
  String? editandoNumeroPedidoFijo;
  String? clienteEnCurso;
  List<Map<String, dynamic>> productosEnCurso = [];

  void cargarPedidoParaEditar(int id, String numeroPedido, String cliente, List<Map<String, dynamic>> productos) {
    setState(() {
      editandoPedidoId = id;
      editandoNumeroPedidoFijo = numeroPedido;
      clienteEnCurso = cliente;
      productosEnCurso = List.from(productos);
      _indiceActual = 0;
    });
    if (pageController.hasClients) {
      pageController.jumpToPage(0);
    }
  }

  void limpiarPedidoEnCurso() {
    setState(() {
      editandoPedidoId = null;
      editandoNumeroPedidoFijo = null;
      clienteEnCurso = null;
      productosEnCurso.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: pageController,
        onPageChanged: (index) {
          setState(() {
            _indiceActual = index;
          });
        },
        children: const [
          VistaCrearPedido(),
          VistaHistorialPedidos(),
          VistaGestionClientes(),
          VistaGestionProductos(),
          VistaResumenGeneral(),
          VistaResumenProductos(),
          VistaExportarPdf(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _indiceActual,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.indigo,
        unselectedItemColor: Colors.grey,
        onTap: (index) {
          setState(() {
            _indiceActual = index;
          });
          pageController.jumpToPage(index);
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.add_shopping_cart), label: 'Crear'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'Historial'),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Clientes'),
          BottomNavigationBarItem(icon: Icon(Icons.inventory), label: 'Productos'),
          BottomNavigationBarItem(icon: Icon(Icons.analytics), label: 'Resumen'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'Por Prod.'),
          BottomNavigationBarItem(icon: Icon(Icons.picture_as_pdf), label: 'Exportar'),
        ],
      ),
    );
  }
}

// ==========================================
// 1. PESTAÑA: CREAR PEDIDO
// ==========================================
class VistaCrearPedido extends StatefulWidget {
  const VistaCrearPedido({super.key});

  @override
  State<VistaCrearPedido> createState() => _VistaCrearPedidoState();
}

class _VistaCrearPedidoState extends State<VistaCrearPedido> {
  Future<int> _obtenerSiguienteNumeroPedido() async {
    final db = await DatabaseHelper.instance.database;
    final resultado = await db.rawQuery('SELECT COUNT(*) as total FROM pedidos');
    int count = Sqflite.firstIntValue(resultado) ?? 0;
    return (count % 99) + 1;
  }

  void _guardarPedido() async {
    final mainState = context.findAncestorStateOfType<MenuPrincipalState>();
    if (mainState?.clienteEnCurso == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Debe seleccionar un cliente obligatoriamente')),
      );
      return;
    }
    if (mainState == null || mainState.productosEnCurso.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agregue al menos un producto al pedido')),
      );
      return;
    }

    String numPedidoStr;
    if (mainState.editandoNumeroPedidoFijo != null) {
      numPedidoStr = mainState.editandoNumeroPedidoFijo!;
    } else {
      int numSeq = await _obtenerSiguienteNumeroPedido();
      numPedidoStr = 'Pedido #${numSeq.toString().padLeft(2, '0')}';
    }

    double total = mainState.productosEnCurso.fold<double>(
      0.0, 
      (sum, item) => sum + ((item['precio'] as num).toDouble() * (item['cantidad'] as num).toDouble())
    );

    String fecha = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());

    String productosStr = mainState.productosEnCurso.map((p) {
      String com = (p['comentario'] != null && p['comentario'].toString().trim().isNotEmpty)
          ? ' [${p['comentario']}]'
          : '';
      return "${p['nombre']}$com (x${p['cantidad']})";
    }).join('; ');

    final db = await DatabaseHelper.instance.database;
    
    if (mainState.editandoPedidoId != null) {
      await db.update('pedidos', {
        'numero_pedido': numPedidoStr,
        'cliente': mainState.clienteEnCurso,
        'productos_json': productosStr,
        'total': total,
      }, where: 'id = ?', whereArgs: [mainState.editandoPedidoId]);
    } else {
      await db.insert('pedidos', {
        'numero_pedido': numPedidoStr,
        'cliente': mainState.clienteEnCurso,
        'productos_json': productosStr,
        'total': total,
        'fecha': fecha,
        'semana': 'Sin Asignar',
        'gestionado': 0,
        'incidencia': '',
        'total_real': total,
      });
    }

    mainState.limpiarPedidoEnCurso();
    setState(() {});

    if(!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('¡$numPedidoStr Guardado con éxito!')),
    );
  }

  void _abrirBuscadorClientes() {
    showDialog(
      context: context,
      builder: (context) {
        String filtro = '';
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return Dialog.fullscreen(
              child: Scaffold(
                appBar: AppBar(
                  title: const Text('Buscar Cliente'),
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                body: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      TextField(
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: 'Nombre o código del cliente...',
                          suffixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (val) {
                          setStateDialog(() {
                            filtro = val.trim();
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: FutureBuilder<List<Map<String, dynamic>>>(
                          future: DatabaseHelper.instance.database.then((db) {
                            return db.query('clientes', where: 'nombre LIKE ? OR codigo LIKE ?', whereArgs: ['%$filtro%', '%$filtro%']);
                          }),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                            final clientes = snapshot.data!;
                            if (clientes.isEmpty) {
                              return const Center(child: Text('No se encontraron clientes', style: TextStyle(color: Colors.grey)));
                            }
                            return ListView.builder(
                              itemCount: clientes.length,
                              itemBuilder: (context, index) {
                                final c = clientes[index];
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: ListTile(
                                    title: Text('Cod: ${c['codigo']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.indigo)),
                                    subtitle: Text('${c['nombre']}\nTel: ${c['telefono']}', style: const TextStyle(fontSize: 14)),
                                    isThreeLine: true,
                                    onTap: () {
                                      final mainState = this.context.findAncestorStateOfType<MenuPrincipalState>();
                                      if (mainState != null) {
                                        mainState.setState(() {
                                          mainState.clienteEnCurso = c['nombre'];
                                        });
                                      }
                                      Navigator.pop(context);
                                      setState(() {});
                                    },
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _abrirBuscadorProductos() {
    showDialog(
      context: context,
      builder: (context) {
        String filtro = '';
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return Dialog.fullscreen(
              child: Scaffold(
                appBar: AppBar(
                  title: const Text('Buscar Producto'),
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                body: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      TextField(
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: 'Nombre o código del producto...',
                          suffixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (val) {
                          setStateDialog(() {
                            filtro = val.trim();
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: FutureBuilder<List<Map<String, dynamic>>>(
                          future: DatabaseHelper.instance.database.then((db) {
                            return db.query('productos', where: 'nombre LIKE ? OR codigo LIKE ?', whereArgs: ['%$filtro%', '%$filtro%']);
                          }),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                            final productos = snapshot.data!;
                            if (productos.isEmpty) {
                              return const Center(child: Text('No se encontraron productos', style: TextStyle(color: Colors.grey)));
                            }
                            return ListView.builder(
                              itemCount: productos.length,
                              itemBuilder: (context, index) {
                                final p = productos[index];
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: ListTile(
                                    title: Text('Cod: ${p['codigo']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.indigo)),
                                    subtitle: Text('${p['nombre']}\nPrecio: L ${p['precio'].toStringAsFixed(2)}', style: const TextStyle(fontSize: 14)),
                                    isThreeLine: true,
                                    onTap: () {
                                      final mainState = this.context.findAncestorStateOfType<MenuPrincipalState>();
                                      if (mainState != null) {
                                        mainState.setState(() {
                                          var existenteIndex = mainState.productosEnCurso.indexWhere(
                                            (item) => item['nombre'] == p['nombre'],
                                          );
                                          if (existenteIndex != -1) {
                                            mainState.productosEnCurso[existenteIndex]['cantidad']++;
                                          } else {
                                            mainState.productosEnCurso.insert(0, {
                                              'nombre': p['nombre'],
                                              'precio': p['precio'],
                                              'cantidad': 1,
                                              'comentario': '',
                                            });
                                          }
                                        });
                                      }
                                      Navigator.pop(context);
                                      setState(() {});
                                    },
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _pedirComentario(int index) {
    final mainState = context.findAncestorStateOfType<MenuPrincipalState>();
    if (mainState == null) return;
    TextEditingController comCtrl = TextEditingController(text: mainState.productosEnCurso[index]['comentario'] ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Comentario / Detalle'),
        content: TextField(
          controller: comCtrl,
          decoration: const InputDecoration(labelText: 'Ej. Color rojo, Talla L, Fragancia vainilla...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () {
              setState(() {
                mainState.productosEnCurso[index]['comentario'] = comCtrl.text.trim();
              });
              Navigator.pop(context);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  void _mostrarDialogoGestionProducto(int index) {
    final mainState = context.findAncestorStateOfType<MenuPrincipalState>();
    if (mainState == null) return;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          if (index >= mainState.productosEnCurso.length) return const SizedBox.shrink();
          var item = mainState.productosEnCurso[index];
          return AlertDialog(
            title: Text(item['nombre'], style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Cantidad actual: ${item['cantidad']}', style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                      onPressed: () {
                        mainState.setState(() {
                          if (item['cantidad'] > 1) {
                            item['cantidad']--;
                          } else {
                            mainState.productosEnCurso.removeAt(index);
                          }
                        });
                        setStateDialog(() {});
                        setState(() {});
                        if (index >= mainState.productosEnCurso.length) {
                          Navigator.pop(context);
                        }
                      },
                      icon: const Icon(Icons.remove, size: 16),
                      label: const Text('Menos'),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                      onPressed: () {
                        mainState.setState(() {
                          item['cantidad']++;
                        });
                        setStateDialog(() {});
                        setState(() {});
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Más'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () {
                    mainState.setState(() {
                      mainState.productosEnCurso.removeAt(index);
                    });
                    Navigator.pop(context);
                    setState(() {});
                  },
                  icon: const Icon(Icons.delete),
                  label: const Text('Eliminar del pedido'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cerrar'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mainState = context.findAncestorStateOfType<MenuPrincipalState>();
    bool estaEditando = mainState?.editandoPedidoId != null;
    double totalActual = mainState?.productosEnCurso.fold<double>(
      0.0, 
      (sum, item) => sum + ((item['precio'] as num).toDouble() * (item['cantidad'] as num).toDouble())
    ) ?? 0.0;

    return Scaffold(
      appBar: AppBar(
        title: Text(estaEditando ? 'Editando ${mainState?.editandoNumeroPedidoFijo}' : 'Crear Pedido'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Guardar Pedido',
            onPressed: mainState?.clienteEnCurso == null ? null : _guardarPedido,
          ),
          if (estaEditando)
            IconButton(
              icon: const Icon(Icons.close, color: Colors.amberAccent),
              tooltip: 'Cancelar Edición',
              onPressed: () => setState(() => mainState?.limpiarPedidoEnCurso()),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            GestureDetector(
              onTap: _abrirBuscadorClientes,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.indigo.shade300, width: 1.5),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.indigo.shade50.withOpacity(0.5),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, color: Colors.indigo),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        mainState?.clienteEnCurso ?? 'Toca aquí para buscar y seleccionar cliente...',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: mainState?.clienteEnCurso != null ? FontWeight.bold : FontWeight.normal,
                          color: mainState?.clienteEnCurso != null ? Colors.black87 : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _abrirBuscadorProductos,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.indigo.shade300, width: 1.5),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.indigo.shade50.withOpacity(0.5),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.search, color: Colors.indigo),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Toca aquí para buscar y agregar productos...',
                        style: TextStyle(fontSize: 14, color: Colors.black87, fontWeight: FontWeight.w500),
                      ),
                    ),
                    Icon(Icons.add_box, color: Colors.indigo),
                  ],
                ),
              ),
            ),
            const Divider(height: 20),
            Expanded(
              child: (mainState?.productosEnCurso.isEmpty ?? true)
                  ? const Center(
                      child: Text('No hay productos agregados todavía.', style: TextStyle(color: Colors.grey, fontSize: 13)),
                    )
                  : ListView.builder(
                      itemCount: mainState?.productosEnCurso.length ?? 0,
                      itemBuilder: (context, idx) {
                        var item = mainState!.productosEnCurso[idx];
                        String comText = (item['comentario'] != null && item['comentario'].toString().isNotEmpty)
                            ? item['comentario']
                            : '';
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 8.0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: InkWell(
                                    onTap: () => _pedirComentario(idx),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(item['nombre'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                        const SizedBox(height: 2),
                                        Text('Cant: ${item['cantidad']} x L ${item['precio']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                        if (comText.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text('Detalle: $comText', style: const TextStyle(fontSize: 12, color: Colors.indigo, fontStyle: FontStyle.italic)),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                InkWell(
                                  onTap: () => _mostrarDialogoGestionProducto(idx),
                                  child: Padding(
                                    padding: const EdgeInsets.all(4.0),
                                    child: Text(
                                      'L ${(item['precio'] * item['cantidad']).toStringAsFixed(2)}', 
                                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.indigo),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.indigo.shade200),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total del Pedido:', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  Text('L ${totalActual.toStringAsFixed(2)}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.indigo)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 2. PESTAÑA: HISTORIAL DE PEDIDOS
// ==========================================
class VistaHistorialPedidos extends StatefulWidget {
  const VistaHistorialPedidos({super.key});

  @override
  State<VistaHistorialPedidos> createState() => _VistaHistorialPedidosState();
}

class _VistaHistorialPedidosState extends State<VistaHistorialPedidos> {
  Set<int> pedidosSeleccionadosIds = {};

  Future<void> _resetearConteo() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('pedidos');
    pedidosSeleccionadosIds.clear();
    setState(() {});
    if(!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Conteo de pedidos reseteado a 0')));
  }

  void _enviarWhatsApp(String cliente, String productos, double total) async {
    String mensaje = "Hola $cliente, tu pedido consta de: $productos. Total: L ${total.toStringAsFixed(2)}. ¡Gracias por tu compra!";
    final url = Uri.parse("https://wa.me/?text=${Uri.encodeComponent(mensaje)}");
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _generarPdfPedidoIndividual(Map<String, dynamic> pedido) async {
    final db = await DatabaseHelper.instance.database;
    
    // Obtenemos catálogos para extraer códigos de cliente y productos
    final productosDb = await db.query('productos');
    final clientesDb = await db.query('clientes');

    Map<String, String> codigosProdMap = {};
    for (var prod in productosDb) {
      codigosProdMap[prod['nombre'].toString().trim()] = prod['codigo'].toString().trim();
    }

    Map<String, String> codigosClientMap = {};
    for (var cli in clientesDb) {
      codigosClientMap[cli['nombre'].toString().trim()] = cli['codigo'].toString().trim();
    }

    String nombreCliente = pedido['cliente'].toString().trim();
    String codigoCliente = codigosClientMap[nombreCliente] ?? 'S/C';

    final pdf = pw.Document();
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          List<pw.Widget> detalleWidgets = [];
          String prodString = pedido['productos_json'].toString();
          List<String> items = prodString.split(';');
          for (var item in items) {
            if (item.trim().isEmpty) continue;
            String texto = item.trim();
            int cant = 1;
            if (texto.contains('(x')) {
              var splitCant = texto.split('(x');
              texto = splitCant[0].trim();
              try {
                cant = int.parse(splitCant[1].replaceAll(')', '').trim());
              } catch (_) {}
            }
            String nombreProd = texto;
            String detalleProd = '';
            if (texto.contains('[') && texto.endsWith(']')) {
              int startIdx = texto.lastIndexOf('[');
              nombreProd = texto.substring(0, startIdx).trim();
              detalleProd = texto.substring(startIdx + 1, texto.length - 1).trim();
            }
            String codigoProd = codigosProdMap[nombreProd] ?? 'S/C';

            detalleWidgets.add(
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 10, bottom: 4),
                child: pw.Row(
                  children: [
                    pw.Text('[$codigoProd] ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                    pw.Expanded(
                      child: pw.Text('$nombreProd (x$cant)${detalleProd.isNotEmpty ? ' [$detalleProd]' : ''}', style: const pw.TextStyle(fontSize: 10)),
                    ),
                  ],
                ),
              ),
            );
          }

          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Header(
                level: 0,
                child: pw.Text('Comprobante de Pedido - APP VENTAS HOB', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
              ),
              pw.SizedBox(height: 10),
              pw.Text('Número de Pedido: ${pedido['numero_pedido']}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
              pw.Text('Cliente: [$codigoCliente] $nombreCliente', style: const pw.TextStyle(fontSize: 12)),
              pw.Text('Fecha: ${pedido['fecha']}', style: const pw.TextStyle(fontSize: 12)),
              pw.Text('Semana: ${pedido['semana'] ?? 'Sin Asignar'}', style: const pw.TextStyle(fontSize: 12)),
              pw.Divider(height: 20),
              pw.Text('Detalle de Productos:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              ...detalleWidgets,
              pw.Divider(height: 20),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Total del Pedido:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text('L ${(pedido['total'] as num).toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ],
              ),
            ],
          );
        },
      ),
    );

    String nombreArchivo = "Pedido_${pedido['numero_pedido'].toString().replaceAll('#', '')}_$nombreCliente.pdf";
    await guardarPdfEnDescargas(pdf, nombreArchivo);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF guardado en descargas: $nombreArchivo')));
  }

  void _mostrarAsignarSemanaDialog() {
    if (pedidosSeleccionadosIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Seleccione al menos un pedido')));
      return;
    }
    TextEditingController semanaCtrl = TextEditingController(text: 'Semana 01');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Asignar a Semana'),
        content: TextField(
          controller: semanaCtrl,
          decoration: const InputDecoration(labelText: 'Ej. Semana 01, Semana 02...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              String sem = semanaCtrl.text.trim();
              if (sem.isNotEmpty) {
                final db = await DatabaseHelper.instance.database;
                for (int id in pedidosSeleccionadosIds) {
                  await db.update('pedidos', {'semana': sem}, where: 'id = ?', whereArgs: [id]);
                }
                pedidosSeleccionadosIds.clear();
                setState(() {});
                if(!mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Pedidos asignados a $sem')));
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  void _mostrarMenuOpciones(Map<String, dynamic> pedido) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.picture_as_pdf, color: Colors.indigo),
              title: const Text('Generar PDF por Pedido'),
              onTap: () {
                Navigator.pop(context);
                _generarPdfPedidoIndividual(pedido);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.blue),
              title: const Text('Editar Pedido (Modificar en Crear)'),
              onTap: () {
                Navigator.pop(context);
                _mandarAEditar(pedido);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Eliminar Pedido'),
              onTap: () async {
                Navigator.pop(context);
                final db = await DatabaseHelper.instance.database;
                await db.delete('pedidos', where: 'id = ?', whereArgs: [pedido['id']]);
                setState(() {});
              },
            ),
          ],
        );
      },
    );
  }

  void _mandarAEditar(Map<String, dynamic> pedido) async {
    List<Map<String, dynamic>> productosParsed = [];
    String prodString = pedido['productos_json'].toString();
    
    List<String> items = prodString.split(';');
    for (var item in items) {
      if (item.trim().isEmpty) continue;
      try {
        String texto = item.trim();
        int cant = 1;
        if (texto.contains('(x')) {
          var splitCant = texto.split('(x');
          texto = splitCant[0].trim();
          cant = int.parse(splitCant[1].replaceAll(')', '').trim());
        }
        String nombre = texto;
        String comentario = '';
        if (texto.contains('[') && texto.endsWith(']')) {
          int startIdx = texto.lastIndexOf('[');
          nombre = texto.substring(0, startIdx).trim();
          comentario = texto.substring(startIdx + 1, texto.length - 1).trim();
        }

        final db = await DatabaseHelper.instance.database;
        var prodDb = await db.query('productos', where: 'nombre = ?', whereArgs: [nombre], limit: 1);
        double precio = 0.0;
        if (prodDb.isNotEmpty) {
          precio = (prodDb.first['precio'] as num).toDouble();
        }

        productosParsed.add({
          'nombre': nombre,
          'precio': precio,
          'cantidad': cant,
          'comentario': comentario,
        });
      } catch (_) {}
    }

    final mainState = context.findAncestorStateOfType<MenuPrincipalState>();
    if (mainState != null) {
      mainState.cargarPedidoParaEditar(
        pedido['id'],
        pedido['numero_pedido'].toString(),
        pedido['cliente'].toString(),
        productosParsed,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Historial de Pedidos'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          if (pedidosSeleccionadosIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.bookmark_add),
              tooltip: 'Asignar Semana',
              onPressed: _mostrarAsignarSemanaDialog,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Resetear Conteo',
            onPressed: _resetearConteo,
          )
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: DatabaseHelper.instance.database.then((db) async {
          final pedidos = await db.query('pedidos', orderBy: 'id DESC');
          final clientes = await db.query('clientes');
          final productos = await db.query('productos');
          return {'pedidos': pedidos, 'clientes': clientes, 'productos': productos};
        }),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          
          final data = snapshot.data!;
          final pedidos = data['pedidos'] as List<Map<String, dynamic>>;
          final clientes = data['clientes'] as List<Map<String, dynamic>>;
          final productos = data['productos'] as List<Map<String, dynamic>>;

          Map<String, String> codigosClientMap = {};
          for (var c in clientes) {
            codigosClientMap[c['nombre'].toString().trim()] = c['codigo'].toString().trim();
          }

          Map<String, String> codigosProdMap = {};
          for (var p in productos) {
            codigosProdMap[p['nombre'].toString().trim()] = p['codigo'].toString().trim();
          }

          if (pedidos.isEmpty) return const Center(child: Text('No hay pedidos registrados.'));
          
          return ListView.builder(
            itemCount: pedidos.length,
            itemBuilder: (context, index) {
              final p = pedidos[index];
              int pId = p['id'] as int;
              bool seleccionado = pedidosSeleccionadosIds.contains(pId);
              String prodString = p['productos_json']?.toString() ?? '';
              List<String> itemsList = prodString.split(';');
              String semanaActual = p['semana']?.toString() ?? 'Sin Asignar';
              
              String nombreCliente = p['cliente'].toString().trim();
              String codigoCliente = codigosClientMap[nombreCliente] ?? 'S/C';

              return Card(
                color: seleccionado ? Colors.indigo.shade50 : Colors.white,
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Checkbox(
                            value: seleccionado,
                            onChanged: (val) {
                              setState(() {
                                if (val == true) {
                                  pedidosSeleccionadosIds.add(pId);
                                } else {
                                  pedidosSeleccionadosIds.remove(pId);
                                }
                              });
                            },
                          ),
                          Expanded(
                            child: Text(
                              '${p['numero_pedido']} - [$codigoCliente] $nombreCliente [$semanaActual]', 
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.indigo),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.share, color: Colors.green, size: 20),
                            onPressed: () => _enviarWhatsApp(nombreCliente, prodString, (p['total'] as num).toDouble()),
                            constraints: const BoxConstraints(),
                            padding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                      const Divider(height: 12),
                      const Text('Productos:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 4),
                      ...itemsList.map((itemStr) {
                        if (itemStr.trim().isEmpty) return const SizedBox.shrink();
                        String texto = itemStr.trim();
                        int cant = 1;
                        if (texto.contains('(x')) {
                          var splitCant = texto.split('(x');
                          texto = splitCant[0].trim();
                          try {
                            cant = int.parse(splitCant[1].replaceAll(')', '').trim());
                          } catch (_) {}
                        }
                        String nombreProd = texto;
                        String detalleProd = '';
                        if (texto.contains('[') && texto.endsWith(']')) {
                          int startIdx = texto.lastIndexOf('[');
                          nombreProd = texto.substring(0, startIdx).trim();
                          detalleProd = texto.substring(startIdx + 1, texto.length - 1).trim();
                        }
                        String codigoProd = codigosProdMap[nombreProd] ?? 'S/C';

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6.0, left: 8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '• [$codigoProd] $nombreProd (x$cant)', 
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                              ),
                              if (detalleProd.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(left: 16.0, top: 1.0),
                                  child: Text(
                                    detalleProd, 
                                    style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 11, color: Colors.grey),
                                  ),
                                ),
                            ],
                          ),
                        );
                      }),
                      const Divider(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Total: L ${(p['total'] as num).toStringAsFixed(2)}', 
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.green),
                          ),
                          Text(
                            'Fecha: ${p['fecha']}', 
                            style: const TextStyle(color: Colors.grey, fontSize: 11),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => _mostrarMenuOpciones(p),
                          icon: const Icon(Icons.more_vert, size: 16),
                          label: const Text('Opciones', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ==========================================
// 3. GESTIÓN CLIENTES
// ==========================================
class VistaGestionClientes extends StatefulWidget {
  const VistaGestionClientes({super.key});

  @override
  State<VistaGestionClientes> createState() => _VistaGestionClientesState();
}

class _VistaGestionClientesState extends State<VistaGestionClientes> {
  bool sincronizando = false;

  Future<void> _sincronizar() async {
    setState(() => sincronizando = true);
    try {
      final res = await http.get(Uri.parse(urlClientesCSV));
      if (res.statusCode == 200) {
        await DatabaseHelper.instance.sincronizarClientesDesdeCSV(res.body);
        if(!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Clientes sincronizados')));
        setState(() {});
      }
    } catch (e) {
      if(!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if(mounted) setState(() => sincronizando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gestión de Clientes'), backgroundColor: Colors.indigo, foregroundColor: Colors.white),
      floatingActionButton: FloatingActionButton(
        onPressed: sincronizando ? null : _sincronizar,
        child: const Icon(Icons.cloud_download),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: DatabaseHelper.instance.database.then((db) => db.query('clientes')),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final lista = snapshot.data!;
          if(lista.isEmpty) return const Center(child: Text('Presiona el botón inferior para sincronizar Clientes.'));
          return ListView.builder(
            itemCount: lista.length,
            itemBuilder: (context, i) => ListTile(
              dense: true,
              title: Text('Cod: ${lista[i]['codigo']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.indigo)),
              subtitle: Text('${lista[i]['nombre']} | Tel: ${lista[i]['telefono']}', style: const TextStyle(fontSize: 13)),
            ),
          );
        },
      ),
    );
  }
}

// ==========================================
// 4. GESTIÓN PRODUCTOS
// ==========================================
class VistaGestionProductos extends StatefulWidget {
  const VistaGestionProductos({super.key});

  @override
  State<VistaGestionProductos> createState() => _VistaGestionProductosState();
}

class _VistaGestionProductosState extends State<VistaGestionProductos> {
  bool sincronizando = false;

  Future<void> _sincronizar() async {
    setState(() => sincronizando = true);
    try {
      final res = await http.get(Uri.parse(urlProductosCSV));
      if (res.statusCode == 200) {
        await DatabaseHelper.instance.sincronizarProductosDesdeCSV(res.body);
        if(!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Productos sincronizados')));
        setState(() {});
      }
    } catch (e) {
      if(!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if(mounted) setState(() => sincronizando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gestión de Productos'), backgroundColor: Colors.indigo, foregroundColor: Colors.white),
      floatingActionButton: FloatingActionButton(
        onPressed: sincronizando ? null : _sincronizar,
        child: const Icon(Icons.cloud_download),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: DatabaseHelper.instance.database.then((db) => db.query('productos')),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final lista = snapshot.data!;
          if(lista.isEmpty) return const Center(child: Text('Presiona el botón inferior para sincronizar Productos.'));
          return ListView.builder(
            itemCount: lista.length,
            itemBuilder: (context, i) => ListTile(
              dense: true,
              title: Text('Cod: ${lista[i]['codigo']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.indigo)),
              subtitle: Text('${lista[i]['nombre']} - Precio: L ${(lista[i]['precio'] as num).toStringAsFixed(2)}', style: const TextStyle(fontSize: 13)),
            ),
          );
        },
      ),
    );
  }
}

// ==========================================
// 5. RESUMEN GENERAL
// ==========================================
class VistaResumenGeneral extends StatelessWidget {
  const VistaResumenGeneral({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Resumen General'), backgroundColor: Colors.indigo, foregroundColor: Colors.white),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: DatabaseHelper.instance.database.then((db) => db.query('pedidos')),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final pedidos = snapshot.data!;
          double totalGlobal = pedidos.fold(0, (sum, item) => sum + (item['total'] as num).toDouble());
          
          Map<String, double> porFecha = {};
          Map<String, double> porCliente = {};
          
          for (var p in pedidos) {
            String fecha = p['fecha'].toString().substring(0, 10);
            String cliente = p['cliente'];
            double total = (p['total'] as num).toDouble();
            porFecha[fecha] = (porFecha[fecha] ?? 0) + total;
            porCliente[cliente] = (porCliente[cliente] ?? 0) + total;
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: Colors.indigo[50],
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Venta Total General: L ${totalGlobal.toStringAsFixed(2)}', 
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
              const Divider(),
              const Text('Ventas por Fecha:', style: TextStyle(fontWeight: FontWeight.bold)),
              ...porFecha.entries.map((e) => ListTile(title: Text(e.key), trailing: Text('L ${e.value.toStringAsFixed(2)}'))),
              const Divider(),
              const Text('Ventas por Cliente:', style: TextStyle(fontWeight: FontWeight.bold)),
              ...porCliente.entries.map((e) => ListTile(title: Text(e.key), trailing: Text('L ${e.value.toStringAsFixed(2)}'))),
            ],
          );
        },
      ),
    );
  }
}

// ==========================================
// 6. RESUMEN POR PRODUCTO
// ==========================================
class VistaResumenProductos extends StatefulWidget {
  const VistaResumenProductos({super.key});

  @override
  State<VistaResumenProductos> createState() => _VistaResumenProductosState();
}

class _VistaResumenProductosState extends State<VistaResumenProductos> {
  String tipoVista = 'unidades';

  Future<void> _generarReporteProductosPdf() async {
    final db = await DatabaseHelper.instance.database;
    final pedidos = await db.query('pedidos');
    final productosDb = await db.query('productos');

    Map<String, double> preciosMap = {};
    Map<String, String> codigosMap = {};
    for (var prod in productosDb) {
      String nombreProd = prod['nombre'].toString().trim();
      preciosMap[nombreProd] = (prod['precio'] as num).toDouble();
      codigosMap[nombreProd] = prod['codigo'].toString().trim();
    }

    Map<String, int> conteoUnidades = {};
    Map<String, double> valorVentas = {};

    for (var p in pedidos) {
      String prodString = p['productos_json'].toString();
      List<String> items = prodString.split(';');
      for (var item in items) {
        if (item.trim().isEmpty) continue;
        try {
          int idxCant = item.lastIndexOf('(x');
          if (idxCant == -1) continue;
          
          String nombreBruto = item.substring(0, idxCant).trim();
          String cantStr = item.substring(idxCant + 2).replaceAll(')', '').trim();
          int cant = int.parse(cantStr);

          String nombreLimpio = nombreBruto;
          if (nombreBruto.contains('[')) {
            nombreLimpio = nombreBruto.substring(0, nombreBruto.lastIndexOf('[')).trim();
          } else if (nombreBruto.contains('(')) {
            nombreLimpio = nombreBruto.substring(0, nombreBruto.lastIndexOf('(')).trim();
          }

          conteoUnidades[nombreLimpio] = (conteoUnidades[nombreLimpio] ?? 0) + cant;
          double precioUnit = preciosMap[nombreLimpio] ?? 0.0;
          valorVentas[nombreLimpio] = (valorVentas[nombreLimpio] ?? 0.0) + (precioUnit * cant);
        } catch (_) {}
      }
    }

    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Text('Reporte Acumulado por Productos - APP VENTAS HOB', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
            ),
            pw.SizedBox(height: 10),
            pw.Table.fromTextArray(
              headers: ['Código', 'Producto', 'Unidades', 'Total Ventas'],
              data: conteoUnidades.entries.map((e) {
                String prod = e.key;
                int unidades = e.value;
                double valor = valorVentas[prod] ?? 0.0;
                String codigo = codigosMap[prod] ?? 'S/C';
                return [codigo, prod, unidades.toString(), 'L ${valor.toStringAsFixed(2)}'];
              }).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.indigo700),
              cellStyle: const pw.TextStyle(fontSize: 10),
            ),
          ];
        },
      ),
    );

    try {
      Uint8List bytes = await pdf.save();
      
      // Selector de carpeta interactivo
      String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: 'Elija dónde guardar el Resumen de Productos:',
        fileName: 'Reporte_Acumulado_Productos.pdf',
        bytes: bytes,
      );

      if (outputFile != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('¡Reporte guardado con éxito!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar el PDF: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resumen por Producto'), 
        backgroundColor: Colors.indigo, 
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Descargar PDF de Productos',
            onPressed: _generarReporteProductosPdf,
          ),
        ],
      ),
      body: FutureBuilder<List<List<Map<String, dynamic>>>>(
        future: Future.wait([
          DatabaseHelper.instance.database.then((db) => db.query('pedidos')),
          DatabaseHelper.instance.database.then((db) => db.query('productos')),
        ]),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          
          final pedidos = snapshot.data![0];
          final productosDb = snapshot.data![1];

          Map<String, double> preciosMap = {};
          for (var prod in productosDb) {
            preciosMap[prod['nombre'].toString().trim()] = (prod['precio'] as num).toDouble();
          }

          Map<String, int> conteoUnidades = {};
          Map<String, double> valorVentas = {};

          for (var p in pedidos) {
            String prodString = p['productos_json'].toString();
            List<String> items = prodString.split(';');
            for (var item in items) {
              if (item.trim().isEmpty) continue;
              try {
                int idxCant = item.lastIndexOf('(x');
                if (idxCant == -1) continue;

                String nombreBruto = item.substring(0, idxCant).trim();
                String cantStr = item.substring(idxCant + 2).replaceAll(')', '').trim();
                int cant = int.parse(cantStr);
                
                String nombreLimpio = nombreBruto;
                if (nombreBruto.contains('[')) {
                  nombreLimpio = nombreBruto.substring(0, nombreBruto.lastIndexOf('[')).trim();
                } else if (nombreBruto.contains('(')) {
                  nombreLimpio = nombreBruto.substring(0, nombreBruto.lastIndexOf('(')).trim();
                }

                conteoUnidades[nombreLimpio] = (conteoUnidades[nombreLimpio] ?? 0) + cant;
                double precioUnit = preciosMap[nombreLimpio] ?? 0.0;
                valorVentas[nombreLimpio] = (valorVentas[nombreLimpio] ?? 0.0) + (precioUnit * cant);
              } catch (_) {}
            }
          }

          var listaOrdenadaUnidades = conteoUnidades.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          var listaOrdenadaValor = valorVentas.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Ranking de Productos', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ToggleButtons(
                    isSelected: [tipoVista == 'unidades', tipoVista == 'valor'],
                    onPressed: (index) {
                      setState(() {
                        tipoVista = index == 0 ? 'unidades' : 'valor';
                      });
                    },
                    constraints: const BoxConstraints(minHeight: 30, minWidth: 80),
                    children: const [
                      Text('Unidades', style: TextStyle(fontSize: 12)),
                      Text('Valor (L)', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ],
              ),
              const Divider(),
              if (tipoVista == 'unidades') ...[
                if (listaOrdenadaUnidades.isEmpty)
                  const Center(child: Text('No hay datos'))
                else
                  ...listaOrdenadaUnidades.map((e) => ListTile(
                    title: Text(e.key),
                    trailing: Text('Unidades: ${e.value}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  )),
              ] else ...[
                if (listaOrdenadaValor.isEmpty)
                  const Center(child: Text('No hay datos'))
                else
                  ...listaOrdenadaValor.map((e) => ListTile(
                    title: Text(e.key),
                    trailing: Text('L ${e.value.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo)),
                  )),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ==========================================
// 7. EXPORTAR A PDF (CON CÓDIGOS DE CLIENTE Y PRODUCTO)
// ==========================================
class VistaExportarPdf extends StatefulWidget {
  const VistaExportarPdf({super.key});

  @override
  State<VistaExportarPdf> createState() => _VistaExportarPdfState();
}

class _VistaExportarPdfState extends State<VistaExportarPdf> {
  DateTime? fechaInicio;
  DateTime? fechaFin;

  Future<void> _generarReporteGeneralPdf() async {
    final db = await DatabaseHelper.instance.database;
    
    final productosDb = await db.query('productos');
    final clientesDb = await db.query('clientes');
    
    if (!mounted) return;

    Map<String, String> codigosProdMap = {};
    for (var prod in productosDb) {
      codigosProdMap[prod['nombre'].toString().trim()] = prod['codigo'].toString().trim();
    }

    Map<String, String> codigosClientMap = {};
    for (var cli in clientesDb) {
      codigosClientMap[cli['nombre'].toString().trim()] = cli['codigo'].toString().trim();
    }

    List<Map<String, dynamic>> pedidos;
    if (fechaInicio != null && fechaFin != null) {
      String inicioStr = DateFormat('yyyy-MM-dd').format(fechaInicio!);
      String finStr = DateFormat('yyyy-MM-dd 23:59').format(fechaFin!);
      pedidos = await db.query(
        'pedidos',
        where: 'fecha >= ? AND fecha <= ?',
        whereArgs: [inicioStr, finStr],
        orderBy: 'fecha ASC',
      );
    } else {
      pedidos = await db.query('pedidos', orderBy: 'fecha ASC');
    }
    if (!mounted) return;

    final pdf = pw.Document();
    double totalGlobal = pedidos.fold(0.0, (sum, p) => sum + (p['total'] as num).toDouble());

    Map<String, List<Map<String, dynamic>>> pedidosPorFecha = {};
    Map<String, double> totalPorFecha = {};
    for (var p in pedidos) {
      String fechaFmt = p['fecha'].toString().substring(0, 10);
      pedidosPorFecha.putIfAbsent(fechaFmt, () => []).add(p);
      totalPorFecha[fechaFmt] = (totalPorFecha[fechaFmt] ?? 0) + (p['total'] as num).toDouble();
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          List<pw.Widget> widgets = [
            pw.Header(
              level: 0,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Reporte General de Ventas - APP VENTAS HOB', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
                  pw.Text(DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()), style: const pw.TextStyle(fontSize: 10)),
                ],
              ),
            ),
            pw.SizedBox(height: 10),
          ];

          pedidosPorFecha.forEach((fecha, listaPedidos) {
            widgets.add(
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                color: PdfColors.indigo50,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Fecha: $fecha', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                    pw.Text('Total Fecha: L ${totalPorFecha[fecha]!.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                  ],
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 6));

            for (var p in listaPedidos) {
              String nombreCliente = p['cliente'].toString().trim();
              String codigoCliente = codigosClientMap[nombreCliente] ?? 'S/C';

              widgets.add(
                pw.Text('${p['numero_pedido']} - [$codigoCliente] $nombreCliente', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
              );

              String prodString = p['productos_json'].toString();
              List<String> items = prodString.split(';');
              for (var item in items) {
                if (item.trim().isEmpty) continue;
                String texto = item.trim();
                int cant = 1;
                if (texto.contains('(x')) {
                  var splitCant = texto.split('(x');
                  texto = splitCant[0].trim();
                  try {
                    cant = int.parse(splitCant[1].replaceAll(')', '').trim());
                  } catch (_) {}
                }
                String nombreProd = texto;
                String detalleProd = '';
                if (texto.contains('[') && texto.endsWith(']')) {
                  int startIdx = texto.lastIndexOf('[');
                  nombreProd = texto.substring(0, startIdx).trim();
                  detalleProd = texto.substring(startIdx + 1, texto.length - 1).trim();
                }

                String codigoProd = codigosProdMap[nombreProd] ?? 'S/C';

                widgets.add(
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(left: 15, bottom: 2),
                    child: pw.Row(
                      children: [
                        pw.Text('[$codigoProd] ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                        pw.Expanded(
                          child: pw.Text('$nombreProd (x$cant)${detalleProd.isNotEmpty ? ' [$detalleProd]' : ''}', style: const pw.TextStyle(fontSize: 10)),
                        ),
                      ],
                    ),
                  ),
                );
              }

              widgets.add(
                pw.Padding(
                  padding: const pw.EdgeInsets.only(left: 15, bottom: 8),
                  child: pw.Text('Total Pedido: L ${(p['total'] as num).toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 10, fontStyle: pw.FontStyle.italic)),
                ),
              );
            }
            widgets.add(pw.Divider(height: 15));
          });

          widgets.add(
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.end,
              children: [
                pw.Text('Total Global: L ${totalGlobal.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
              ],
            ),
          );

          return widgets;
        },
      ),
    );

    try {
      Uint8List bytes = await pdf.save();
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'Reporte_General_Ventas.pdf',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reporte General generado con éxito')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al exportar el PDF: $e')));
    }
  }

  Future<void> _generarReporteConsolidadoIncidencias(String semana) async {
    final db = await DatabaseHelper.instance.database;
    final clientesDb = await db.query('clientes');
    Map<String, String> codigosClientMap = {};
    for (var cli in clientesDb) {
      codigosClientMap[cli['nombre'].toString().trim()] = cli['codigo'].toString().trim();
    }

    final pedidos = await db.query(
      'pedidos', 
      where: 'semana LIKE ? AND gestionado = 1', 
      whereArgs: ['%$semana%'],
      orderBy: 'id DESC',
    );

    if (!mounted) return;

    if (pedidos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay pedidos gestionados para esta semana')));
      return;
    }

    final pdf = pw.Document();
    double totalGlobalTeorico = 0;
    double totalGlobalReal = 0;

    // Obtenemos también productos por si necesitamos mapear en el consolidado
    final productosDb = await db.query('productos');
    Map<String, String> codigosProdMap = {};
    for (var prod in productosDb) {
      codigosProdMap[prod['nombre'].toString().trim()] = prod['codigo'].toString().trim();
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          List<pw.Widget> widgets = [
            pw.Header(
              level: 0,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Reporte Consolidado de Entregas e Incidencias - $semana', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
                  pw.Text(DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()), style: const pw.TextStyle(fontSize: 10)),
                ],
              ),
            ),
            pw.SizedBox(height: 10),
          ];

          for (var p in pedidos) {
            double teorico = (p['total'] as num).toDouble();
            double real = (p['total_real'] as num).toDouble();
            double diferencia = real - teorico;
            String incidencia = p['incidencia']?.toString() ?? '';
            String nombreCliente = p['cliente'].toString().trim();
            String codigoCliente = codigosClientMap[nombreCliente] ?? 'S/C';

            totalGlobalTeorico += teorico;
            totalGlobalReal += real;

            List<pw.Widget> detalleWidgets = [];
            String prodString = p['productos_json'].toString();
            List<String> items = prodString.split(';');
            for (var item in items) {
              if (item.trim().isEmpty) continue;
              String texto = item.trim();
              int cant = 1;
              if (texto.contains('(x')) {
                var splitCant = texto.split('(x');
                texto = splitCant[0].trim();
                try {
                  cant = int.parse(splitCant[1].replaceAll(')', '').trim());
                } catch (_) {}
              }
              String nombreProd = texto;
              String detalleProd = '';
              if (texto.contains('[') && texto.endsWith(']')) {
                int startIdx = texto.lastIndexOf('[');
                nombreProd = texto.substring(0, startIdx).trim();
                detalleProd = texto.substring(startIdx + 1, texto.length - 1).trim();
              }
              String codigoProd = codigosProdMap[nombreProd] ?? 'S/C';

              detalleWidgets.add(
                pw.Padding(
                  padding: const pw.EdgeInsets.only(left: 10, bottom: 2),
                  child: pw.Row(
                    children: [
                      pw.Text('[$codigoProd] ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                      pw.Expanded(
                        child: pw.Text('$nombreProd (x$cant)${detalleProd.isNotEmpty ? ' [$detalleProd]' : ''}', style: const pw.TextStyle(fontSize: 10)),
                      ),
                    ],
                  ),
                ),
              );
            }

            widgets.add(
              pw.Container(
                padding: const pw.EdgeInsets.all(8),
                margin: const pw.EdgeInsets.only(bottom: 12),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey400),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('Pedido: ${p['numero_pedido']} - [$codigoCliente] $nombreCliente', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                    pw.SizedBox(height: 4),
                    ...detalleWidgets,
                    pw.Divider(height: 8),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Teórico: L ${teorico.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 10)),
                        pw.Text('Real Entregado: L ${real.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                        pw.Text('Diferencia: L ${diferencia.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 10, color: diferencia < 0 ? PdfColors.red700 : PdfColors.green700)),
                      ],
                    ),
                    if (incidencia.isNotEmpty) ...[
                      pw.SizedBox(height: 4),
                      pw.Text('Incidencia: $incidencia', style: pw.TextStyle(fontSize: 10, fontStyle: pw.FontStyle.italic, color: PdfColors.grey800)),
                    ]
                  ],
                ),
              ),
            );
          }

          widgets.add(pw.SizedBox(height: 10));
          widgets.add(
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              color: PdfColors.indigo50,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Total Consolidado Teórico: L ${totalGlobalTeorico.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                  pw.Text('Total Consolidado Real: L ${totalGlobalReal.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12, color: PdfColors.indigo900)),
                ],
              ),
            ),
          );

          return widgets;
        },
      ),
    );

    try {
      Uint8List bytes = await pdf.save();
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'Reporte_Consolidado_${semana.replaceAll(' ', '_')}.pdf',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reporte consolidado de $semana generado con éxito')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al exportar consolidado: $e')));
    }
  }

  void _abrirDialogoReporteCliente() {
    String semanaFiltro = '';
    String busquedaPedido = '';
    Map<String, dynamic>? pedidoSeleccionado;
    
    final TextEditingController totalLecturaCtrl = TextEditingController();
    final TextEditingController cantidadRealCtrl = TextEditingController();
    final TextEditingController incidenciaCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return Dialog.fullscreen(
              child: Scaffold(
                appBar: AppBar(
                  title: const Text('Gestionar y Exportar por Cliente'),
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                body: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ListView(
                    children: [
                      const Text('1. Buscar por Semana (ej. Semana 01):', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Escribe la semana...',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.calendar_view_week),
                        ),
                        onChanged: (val) {
                          setStateDialog(() {
                            semanaFiltro = val.trim();
                            pedidoSeleccionado = null;
                            totalLecturaCtrl.clear();
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      const Text('2. Filtrar por Pedido o Cliente:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Número de pedido o cliente...',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (val) {
                          setStateDialog(() {
                            busquedaPedido = val.trim();
                            pedidoSeleccionado = null;
                            totalLecturaCtrl.clear();
                          });
                        },
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('3. Pedidos Faltantes de Entrega:', style: TextStyle(fontWeight: FontWeight.bold)),
                          if (semanaFiltro.isNotEmpty)
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                              icon: const Icon(Icons.picture_as_pdf, size: 16),
                              label: Text('Generar PDF $semanaFiltro'),
                              onPressed: () {
                                _generarReporteConsolidadoIncidencias(semanaFiltro);
                                Navigator.pop(context);
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 180,
                        child: FutureBuilder<List<Map<String, dynamic>>>(
                          future: DatabaseHelper.instance.database.then((db) {
                            String whereClause = 'gestionado = 0';
                            List<Object> args = [];
                            if (semanaFiltro.isNotEmpty) {
                              whereClause += ' AND semana LIKE ?';
                              args.add('%$semanaFiltro%');
                            }
                            if (busquedaPedido.isNotEmpty) {
                              whereClause += ' AND (numero_pedido LIKE ? OR cliente LIKE ?)';
                              args.add('%$busquedaPedido%');
                              args.add('%$busquedaPedido%');
                            }
                            return db.query('pedidos', where: whereClause, whereArgs: args, orderBy: 'id DESC');
                          }),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                            final pedidos = snapshot.data!;
                            if (pedidos.isEmpty) {
                              return const Center(child: Text('¡Excelente! No hay pedidos pendientes de entrega con este filtro.'));
                            }
                            return ListView.builder(
                              itemCount: pedidos.length,
                              itemBuilder: (context, index) {
                                final p = pedidos[index];
                                bool esSeleccionado = pedidoSeleccionado != null && pedidoSeleccionado!['id'] == p['id'];
                                return Card(
                                  color: esSeleccionado ? Colors.indigo.shade50 : Colors.white,
                                  child: ListTile(
                                    title: Text('${p['numero_pedido']} - ${p['cliente']} [${p['semana']}]', style: const TextStyle(fontWeight: FontWeight.bold)),
                                    subtitle: Text('Total Teórico: L ${(p['total'] as num).toStringAsFixed(2)}'),
                                    trailing: esSeleccionado ? const Icon(Icons.check_circle, color: Colors.indigo) : const Icon(Icons.radio_button_unchecked),
                                    onTap: () {
                                      setStateDialog(() {
                                        pedidoSeleccionado = p;
                                        totalLecturaCtrl.text = 'L ${(p['total'] as num).toStringAsFixed(2)}';
                                        cantidadRealCtrl.text = p['total'].toString();
                                        incidenciaCtrl.clear();
                                      });
                                    },
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (pedidoSeleccionado != null) ...[
                        Card(
                          elevation: 3,
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Seleccionado: ${pedidoSeleccionado!['numero_pedido']} (${pedidoSeleccionado!['cliente']})',
                                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo)),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: totalLecturaCtrl,
                                  readOnly: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Total del Pedido (Solo Lectura)',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: cantidadRealCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Cantidad / Valor Real Entregado',
                                    border: OutlineInputBorder(),
                                    prefixText: 'L ',
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: incidenciaCtrl,
                                  maxLines: 3,
                                  decoration: const InputDecoration(
                                    labelText: 'Incidencias / Comentarios (Devoluciones, faltantes, etc.)',
                                    border: OutlineInputBorder(),
                                    hintText: 'Ej. Hubo devolución de 2 unidades...',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.indigo,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.save),
                          label: const Text('Guardar Pedido y Continuar con Siguiente'),
                          onPressed: () async {
                            double real = double.tryParse(cantidadRealCtrl.text.trim()) ?? (pedidoSeleccionado!['total'] as num).toDouble();
                            String incidencia = incidenciaCtrl.text.trim();
                            int pId = pedidoSeleccionado!['id'] as int;

                            final db = await DatabaseHelper.instance.database;
                            await db.update('pedidos', {
                              'gestionado': 1,
                              'total_real': real,
                              'incidencia': incidencia,
                            }, where: 'id = ?', whereArgs: [pId]);

                            if (!context.mounted) return;

                            setStateDialog(() {
                              pedidoSeleccionado = null;
                              totalLecturaCtrl.clear();
                              cantidadRealCtrl.clear();
                              incidenciaCtrl.clear();
                            });

                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Pedido guardado y actualizado. Mostrando siguientes pendientes...')),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exportar Reportes PDF'), backgroundColor: Colors.indigo, foregroundColor: Colors.white),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Card(
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Reporte General de Ventas', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('Filtra por fechas o déjalas vacías para exportar todo.', style: TextStyle(fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(fechaInicio == null ? 'Fecha Inicio' : DateFormat('yyyy-MM-dd').format(fechaInicio!)),
                          onPressed: () async {
                            DateTime? picked = await showDatePicker(
                              context: context,
                              initialDate: DateTime.now(),
                              firstDate: DateTime(2023),
                              lastDate: DateTime(2030),
                            );
                            if (picked != null && mounted) setState(() => fechaInicio = picked);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(fechaFin == null ? 'Fecha Fin' : DateFormat('yyyy-MM-dd').format(fechaFin!)),
                          onPressed: () async {
                            DateTime? picked = await showDatePicker(
                              context: context,
                              initialDate: DateTime.now(),
                              firstDate: DateTime(2023),
                              lastDate: DateTime(2030),
                            );
                            if (picked != null && mounted) setState(() => fechaFin = picked);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                      icon: const Icon(Icons.picture_as_pdf),
                      label: const Text('Exportar General'),
                      onPressed: _generarReporteGeneralPdf,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 15),
          Card(
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Reporte Gral por Cliente e Incidencias', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('Selecciona una semana para gestionar entregas, guardar cambios y generar reporte.', style: TextStyle(fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                      icon: const Icon(Icons.assignment_turned_in),
                      label: const Text('Gestionar y Exportar por Cliente'),
                      onPressed: _abrirDialogoReporteCliente,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
