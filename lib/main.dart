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
import 'vista_resumen_por_producto.dart';

// Notificador global para actualizar datos en tiempo real entre pestañas
final ValueNotifier<int> changeNotifierPedidos = ValueNotifier<int>(0); 

// URLs de Google Sheets (Reemplaza con tus enlaces CSV publicados)
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
      title: 'App Ventas ExportPdf',
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
      version: 2,
      onCreate: _createDB,
      onUpgrade: _onUpgradeDB,
    );
  }
  Future _createDB(Database db, int version) async {
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
        grupo TEXT DEFAULT ''
      )
    ''');
  }
  Future _onUpgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await db.execute("ALTER TABLE pedidos ADD COLUMN grupo TEXT DEFAULT ''");
      } catch (_) {}
    }
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

// ==========================================
// MODELOS DE DATOS (Order y WeekGroup)
// ==========================================

class Order {
  final String id;
  final String clientCode;
  final String clientName;
  final double totalAmount;
  double deliveryValue; // Valor editable para la entrega
  String comments;      // Comentarios de la entrega

  Order({
    required this.id,
    required this.clientCode,
    required this.clientName,
    required this.totalAmount,
    double? deliveryValue,
    this.comments = '',
  }) : deliveryValue = deliveryValue ?? totalAmount; // Preliminarmente toma el valor del pedido
}

class WeekGroup {
  final String weekName;
  final List<Order> orders;

  WeekGroup({
    required this.weekName,
    required this.orders,
  });
}

//==================================================FIN

// ==========================================
// MENÚ PRINCIPAL CON PESTAÑAS
// ==========================================
class MenuPrincipal extends StatefulWidget {
  const MenuPrincipal({super.key});

  @override
  State<MenuPrincipal> createState() => MenuPrincipalState();
}

class MenuPrincipalState extends State<MenuPrincipal> {
  int _indiceActual = 0;
  
  // Controlador de páginas para permitir el deslizamiento horizontal
  late final PageController _pageController;

  int? editandoPedidoId;
  String? editandoNumeroPedidoFijo;
  String? clienteEnCurso;
  List<Map<String, dynamic>> productosEnCurso = [];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _indiceActual);
    _cargarBorradorLocal();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _guardarBorradorLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('editandoPedidoId', editandoPedidoId ?? -1);
    await prefs.setString('editandoNumeroPedidoFijo', editandoNumeroPedidoFijo ?? '');
    await prefs.setString('clienteEnCurso', clienteEnCurso ?? '');
    await prefs.setString('productosEnCurso', jsonEncode(productosEnCurso));
  }

  Future<void> _cargarBorradorLocal() async {
    final prefs = await SharedPreferences.getInstance();
    int? idTemp = prefs.getInt('editandoPedidoId');
    if (idTemp != null && idTemp != -1) {
      editandoPedidoId = idTemp;
    }
    String? numTemp = prefs.getString('editandoNumeroPedidoFijo');
    if (numTemp != null && numTemp.isNotEmpty) {
      editandoNumeroPedidoFijo = numTemp;
    }
    String? cliTemp = prefs.getString('clienteEnCurso');
    if (cliTemp != null && cliTemp.isNotEmpty) {
      clienteEnCurso = cliTemp;
    }
    String? prodTemp = prefs.getString('productosEnCurso');
    if (prodTemp != null && prodTemp.isNotEmpty) {
      try {
        List<dynamic> dec = jsonDecode(prodTemp);
        productosEnCurso = dec.map((e) => Map<String, dynamic>.from(e)).toList();
      } catch (_) {}
    }
    setState(() {});
  }

  void cargarPedidoParaEditar(int id, String numeroPedido, String cliente, List<Map<String, dynamic>> productos) {
    setState(() {
      editandoPedidoId = id;
      editandoNumeroPedidoFijo = numeroPedido;
      clienteEnCurso = cliente;
      productosEnCurso = List.from(productos);
      _indiceActual = 0; 
    });
    _pageController.jumpToPage(0);
    _guardarBorradorLocal();
  }

  void limpiarPedidoEnCurso() async {
    setState(() {
      editandoPedidoId = null;
      editandoNumeroPedidoFijo = null;
      clienteEnCurso = null;
      productosEnCurso.clear();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pantallas = [
      VistaCrearPedido(
        onPedidoGuardado: limpiarPedidoEnCurso,
        onCambioDato: _guardarBorradorLocal,
      ),
      const VistaHistorialPedidos(),
      const VistaGestionClientes(),
      const VistaGestionProductos(),
      const VistaResumenGeneral(),
            VistaResumenPorProducto(),
            VistaExportarPdf(),
    ];

    return Scaffold(
      body: PageView(
        controller: _pageController,
        children: pantallas,
        onPageChanged: (index) {
          setState(() {
            _indiceActual = index;
          });
        },
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _indiceActual,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.indigo,
        unselectedItemColor: Colors.grey,
        onTap: (index) {
          setState(() => _indiceActual = index);
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
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
  final VoidCallback onPedidoGuardado;
  final VoidCallback onCambioDato;
  const VistaCrearPedido({super.key, required this.onPedidoGuardado, required this.onCambioDato});
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
        'grupo': '',
      });
    }
    widget.onPedidoGuardado();
    changeNotifierPedidos.value++;
    setState(() {});
    
    if (!mounted) return;
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
                                        widget.onCambioDato();
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
                                            mainState.productosEnCurso.add({
                                              'nombre': p['nombre'],
                                              'precio': p['precio'],
                                              'cantidad': 1,
                                              'comentario': '',
                                            });
                                          }
                                        });
                                        widget.onCambioDato();
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
              widget.onCambioDato();
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
          if (index >= mainState.productosEnCurso.length) {
            return const SizedBox.shrink();
          }
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
                        widget.onCambioDato();
                        setStateDialog(() {});
                        setState(() {});
                        if (index >= mainState.productosEnCurso.length || mainState.productosEnCurso.isEmpty) {
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
                        widget.onCambioDato();
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
                    widget.onCambioDato();
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
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _abrirBuscadorClientes,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade400),
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.grey.shade50,
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(
                          mainState?.clienteEnCurso ?? 'Toca la lupa para seleccionar cliente...',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: mainState?.clienteEnCurso != null ? FontWeight.bold : FontWeight.normal,
                            color: mainState?.clienteEnCurso != null ? Colors.black87 : Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  style: IconButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                  icon: const Icon(Icons.search),
                  tooltip: 'Buscar Cliente',
                  onPressed: _abrirBuscadorClientes,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Expanded(
                  child: Text('Agregar Productos al Pedido:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                ),
                IconButton(
                  style: IconButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                  icon: const Icon(Icons.search),
                  tooltip: 'Buscar Producto',
                  onPressed: _abrirBuscadorProductos,
                ),
              ],
            ),
            const Divider(height: 15),
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
                                        Text(item['nombre'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                        const SizedBox(height: 2),
                                        Text('Cant: ${item['cantidad']} x L ${item['precio']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black87)),
                                        if (comText.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text('Detalle: $comText', style: const TextStyle(fontSize: 10, color: Colors.indigo, fontStyle: FontStyle.italic)),
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
                                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo),
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
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total: L ${totalActual.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo)),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                  onPressed: _guardarPedido,
                  icon: const Icon(Icons.save),
                  label: Text(estaEditando ? 'Actualizar Pedido' : 'Guardar Pedido'),
                ),
              ],
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
  String _filtro = '';
  bool _mostrarArchivados = false;
  @override
  void initState() {
    super.initState();
    changeNotifierPedidos.addListener(_recargar);
  }
  @override
  void dispose() {
    changeNotifierPedidos.removeListener(_recargar);
    super.dispose();
  }
  void _recargar() {
    if (mounted) setState(() {});
  }
  Future<List<Map<String, dynamic>>> _obtenerPedidos() async {
    final db = await DatabaseHelper.instance.database;
    String condGrupo = _mostrarArchivados ? "grupo != ''" : "grupo = ''";
    
    if (_filtro.isEmpty) {
      return await db.query('pedidos', where: condGrupo, orderBy: 'id DESC');
    } else {
      return await db.query(
        'pedidos',
        where: '$condGrupo AND (cliente LIKE ? OR numero_pedido LIKE ?)',
        whereArgs: ['%$_filtro%', '%$_filtro%'],
        orderBy: 'id DESC',
      );
    }
  }
  void _eliminarPedido(int id) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('pedidos', where: 'id = ?', whereArgs: [id]);
    changeNotifierPedidos.value++;
    setState(() {});
  }
  void _confirmarReseteoHistorial() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reiniciar Historial'),
        content: const Text(
          '¿Estás seguro de que deseas eliminar todo el historial de pedidos? Esta acción no se puede deshacer y los nuevos pedidos comenzarán desde el Pedido #01.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('NO', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final db = await DatabaseHelper.instance.database;
              await db.delete('pedidos');
              
              try {
                await db.execute("DELETE FROM sqlite_sequence WHERE name='pedidos'");
              } catch (_) {}
              changeNotifierPedidos.value++;
              setState(() {});
              
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Historial de pedidos reseteado con éxito')),
              );
            },
            child: const Text('SÍ', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
  void _mostrarDialogoAgruparPedidos() async {
    final db = await DatabaseHelper.instance.database;
    final pedidosActivos = await db.query('pedidos', where: "grupo = ''", orderBy: 'id ASC');
    
    if (pedidosActivos.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay pedidos activos disponibles para agrupar')),
      );
      return;
    }
    Set<int> seleccionadosIds = {};
    TextEditingController nombreGrupoController = TextEditingController(text: 'Pedidos Semana 01');
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: const Text('Agrupar y Ocultar Pedidos'),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(
              children: [
                TextField(
                  controller: nombreGrupoController,
                  decoration: const InputDecoration(
                    labelText: 'Nombre del grupo (Ej. Pedidos Semana 01)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                const Text('Selecciona los pedidos a agrupar:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 5),
                Expanded(
                  child: ListView.builder(
                    itemCount: pedidosActivos.length,
                    itemBuilder: (context, index) {
                      var p = pedidosActivos[index];
                      int id = p['id'] as int;
                      String numP = p['numero_pedido']?.toString() ?? 'Pedido #$id';
                      String cli = p['cliente']?.toString() ?? 'Cliente';
                      double tot = (p['total'] as num?)?.toDouble() ?? 0.0;
                      bool isSelected = seleccionadosIds.contains(id);
                      return CheckboxListTile(
                        dense: true,
                        title: Text('$numP - $cli', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        subtitle: Text('Total: L ${tot.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11)),
                        value: isSelected,
                        onChanged: (bool? val) {
                          setStateDialog(() {
                            if (val == true) {
                              seleccionadosIds.add(id);
                            } else {
                              seleccionadosIds.remove(id);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
              onPressed: () async {
                if (seleccionadosIds.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Selecciona al menos un pedido')),
                  );
                  return;
                }
                String nombreGrupo = nombreGrupoController.text.trim();
                if (nombreGrupo.isEmpty) nombreGrupo = 'Grupo de Pedidos';
                for (int id in seleccionadosIds) {
                  await db.update('pedidos', {'grupo': nombreGrupo}, where: 'id = ?', whereArgs: [id]);
                }
                if (!mounted) return;
                Navigator.pop(context);
                changeNotifierPedidos.value++;
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Pedidos agrupados y ocultados en "$nombreGrupo" con éxito')),
                );
              },
              child: const Text('Guardar y Ocultar'),
            ),
          ],
        ),
      ),
    );
  }
  void _editarPedido(Map<String, dynamic> pedido) async {
    final mainState = context.findAncestorStateOfType<MenuPrincipalState>();
    if (mainState == null) return;
     
    List<Map<String, dynamic>> productosEdit = [];
    String prodStr = pedido['productos_json']?.toString() ?? '';
    double totalPedido = (pedido['total'] as num?)?.toDouble() ?? 0.0;
     
    List<String> items = prodStr.split(';');
    int cantidadTotalItems = 0;
     
    List<Map<String, dynamic>> itemsTemporales = [];
    for (var item in items) {
      item = item.trim();
      if (item.isEmpty) continue;
       
      RegExp regExp = RegExp(r'\s*\(x(\d+)\)$');
      Match? match = regExp.firstMatch(item);
      int cantidad = 1;
      String nombreProd = item;
       
      if (match != null) {
        cantidad = int.tryParse(match.group(1) ?? '1') ?? 1;
        nombreProd = item.replaceFirst(regExp, '').trim();
      }
       
      String comentario = '';
      int bracketStart = nombreProd.indexOf('[');
      int bracketEnd = nombreProd.lastIndexOf(']');
      if (bracketStart != -1 && bracketEnd != -1 && bracketEnd > bracketStart) {
        comentario = nombreProd.substring(bracketStart + 1, bracketEnd).trim();
        nombreProd = nombreProd.substring(0, bracketStart).trim();
      }
        
      cantidadTotalItems += cantidad;
      itemsTemporales.add({
        'nombre': nombreProd,
        'cantidad': cantidad,
        'comentario': comentario,
      });
    }
     
    final db = await DatabaseHelper.instance.database;
     
    for (var temp in itemsTemporales) {
      double precioUnitario = 0.0;
      final resProd = await db.query(
        'productos',
        where: 'nombre = ?',
        whereArgs: [temp['nombre']],
        limit: 1,
      );
       
      if (resProd.isNotEmpty) {
        precioUnitario = (resProd.first['precio'] as num?)?.toDouble() ?? 0.0;
      } else if (cantidadTotalItems > 0) {
        precioUnitario = totalPedido / cantidadTotalItems;
      }
      productosEdit.add({
        'nombre': temp['nombre'],
        'precio': precioUnitario,
        'cantidad': temp['cantidad'],
        'comentario': temp['comentario'],
      });
    }
     
    mainState.cargarPedidoParaEditar(
      pedido['id'],
      pedido['numero_pedido'],
      pedido['cliente'],
      productosEdit,
    );
  }
  Future<void> _exportarPdfPedidoIndividual(Map<String, dynamic> pedido) async {
    final pdf = pw.Document();
    final db = await DatabaseHelper.instance.database;
    final clienteNombre = pedido['cliente']?.toString() ?? 'Cliente';
     
    final resCliente = await db.query(
      'clientes',
      where: 'nombre = ?',
      whereArgs: [clienteNombre],
      limit: 1,
    );
     
    String telefonoCliente = '';
    String codigoCliente = '';
    if (resCliente.isNotEmpty) {
      telefonoCliente = resCliente.first['telefono']?.toString() ?? '';
      codigoCliente = resCliente.first['codigo']?.toString() ?? '';
    }
    String prodStr = pedido['productos_json']?.toString() ?? '';
    List<String> items = prodStr.split(';');
    List<List<pw.Widget>> filasProductos = [];
    int conteoLineasProductos = 0; 
     
    for (var item in items) {
      item = item.trim();
      if (item.isEmpty) continue;
      RegExp regExp = RegExp(r'\s*\(x(\d+)\)$');
      Match? match = regExp.firstMatch(item);
      int cantidad = 1;
      String nombreProd = item;
      if (match != null) {
        cantidad = int.tryParse(match.group(1) ?? '1') ?? 1;
        nombreProd = item.replaceFirst(regExp, '').trim();
      }
      String nombreBusqueda = nombreProd;
      int bracketStart = nombreBusqueda.indexOf('[');
      int bracketEnd = nombreBusqueda.lastIndexOf(']');
      if (bracketStart != -1 && bracketEnd != -1 && bracketEnd > bracketStart) {
        nombreBusqueda = nombreBusqueda.substring(0, bracketStart).trim();
      }
      conteoLineasProductos++; 
      double precioUnitario = 0.0;
      String codigoProd = '';
      final resProd = await db.query(
        'productos',
        where: 'nombre = ?',
        whereArgs: [nombreBusqueda],
        limit: 1,
      );
      if (resProd.isNotEmpty) {
        precioUnitario = (resProd.first['precio'] as num?)?.toDouble() ?? 0.0;
        codigoProd = resProd.first['codigo']?.toString() ?? '';
      }
      double valorTotalFila = precioUnitario * cantidad;
      
      String detalleComentario = '';
      int bStart = nombreProd.indexOf('[');
      int bEnd = nombreProd.lastIndexOf(']');
      String nombreLimpio = nombreProd;
      if (bStart != -1 && bEnd != -1 && bEnd > bStart) {
        detalleComentario = nombreProd.substring(bStart + 1, bEnd).trim();
        nombreLimpio = nombreProd.substring(0, bStart).trim();
      }
      
      pw.Widget widgetDescripcion = pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (codigoProd.isNotEmpty)
                pw.Text(
                  '[$codigoProd] ',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10),
                ),
              pw.Expanded(
                child: pw.Text(
                  nombreLimpio,
                  style: pw.TextStyle(fontSize: 10),
                ),
              ),
            ],
          ),
          if (detalleComentario.isNotEmpty)
            pw.Padding(
              padding: pw.EdgeInsets.only(left: codigoProd.isNotEmpty ? (codigoProd.length * 6.0) + 12.0 : 0.0, top: 2.0),
              child: pw.Text(
                detalleComentario,
                style: const pw.TextStyle(
                  fontSize: 10,
                  color: PdfColors.grey700,
                ),
              ),
            ),
        ],
      );
      filasProductos.add([
        pw.Text(cantidad.toString(), style: const pw.TextStyle(fontSize: 10)),
        widgetDescripcion,
        pw.Text(precioUnitario.toStringAsFixed(2), style: const pw.TextStyle(fontSize: 10)),
        pw.Text(valorTotalFila.toStringAsFixed(2), style: const pw.TextStyle(fontSize: 10)),
      ]);
    }
     
    double totalPedido = (pedido['total'] as num?)?.toDouble() ?? 0.0;
   
    Directory? directorio;
    if (Platform.isAndroid) {
      final directories = await getExternalStorageDirectories(type: StorageDirectory.downloads);
      if (directories != null && directories.isNotEmpty) {
        directorio = directories.first;
      } else {
        directorio = await getExternalStorageDirectory();
      }
    } else {
      directorio = await getApplicationDocumentsDirectory();
    }
    String numPedidoRaw = pedido['numero_pedido']?.toString() ?? '';
    if (numPedidoRaw.isEmpty) {
      numPedidoRaw = 'Pedido #${pedido['id']}';
    }
    String numeroPedidoFormateado = numPedidoRaw;
    
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'D  I  S  C  O  S  M  O',
                        style: pw.TextStyle(
                          fontSize: 25,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.indigo900,
                        ),
                      ),
                      pw.SizedBox(height: 5),
                      pw.Text('Productos Industrias Chamer y Mas', style: const pw.TextStyle(fontSize: 14, color: PdfColors.grey700)),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text('FECHA: ${pedido['fecha']?.toString().substring(0, 10) ?? ''}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
                      pw.SizedBox(height: 3),
                      pw.Text(numeroPedidoFormateado, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12, color: PdfColors.indigo900)),
                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 15),
              pw.Divider(color: PdfColors.grey400),
              pw.SizedBox(height: 10),
              pw.Text('CLIENTE:', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.grey700)),
              pw.SizedBox(height: 2),
              pw.Text(clienteNombre, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
              if (codigoCliente.isNotEmpty)
                pw.Text('Código: $codigoCliente', style: const pw.TextStyle(fontSize: 14, color: PdfColors.grey700)),
              if (telefonoCliente.isNotEmpty)
                pw.Text('Teléfono: $telefonoCliente', style: const pw.TextStyle(fontSize: 14, color: PdfColors.grey700)),
             
              pw.SizedBox(height: 20),
              pw.Table(
                border: null,
                columnWidths: {
                  0: const pw.FlexColumnWidth(1),
                  1: const pw.FlexColumnWidth(6),
                  2: const pw.FlexColumnWidth(1),
                  3: const pw.FlexColumnWidth(1),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.indigo),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('Cantidad', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 10)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('Descripción', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 10)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('Precio Unitario', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 10), textAlign: pw.TextAlign.right),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('Valor Total', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 10), textAlign: pw.TextAlign.right),
                      ),
                    ],
                  ),
                  for (var fila in filasProductos)
                    pw.TableRow(
                      children: [
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                          child: fila[0],
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                          child: fila[1],
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                          child: pw.Align(alignment: pw.Alignment.centerRight, child: fila[2]),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                          child: pw.Align(alignment: pw.Alignment.centerRight, child: fila[3]),
                        ),
                      ],
                    ),
                ],
              ),
              pw.SizedBox(height: 20),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Container(
                    padding: const pw.EdgeInsets.all(8),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: PdfColors.grey400),
                      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                    ),
                    width: 180,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Total Productos', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12, color: PdfColors.indigo900)),
                        pw.SizedBox(height: 5),
                        pw.Text('Total de ítems: $conteoLineasProductos', style: const pw.TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  pw.SizedBox(
                    width: 220,
                    child: pw.Column(
                      children: [
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('Subtotal', style: const pw.TextStyle(fontSize: 12)),
                            pw.Text('L ${totalPedido.toStringAsFixed(2)}', style: const pw.TextStyle(fontSize: 12)),
                          ],
                        ),
                        pw.SizedBox(height: 5),
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('ISV', style: const pw.TextStyle(fontSize: 12)),
                            pw.Text('L 0.00', style: const pw.TextStyle(fontSize: 12)),
                          ],
                        ),
                        pw.Divider(color: PdfColors.grey400),
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('Gran Total', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13)),
                            pw.Text('L ${totalPedido.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12, color: PdfColors.indigo900)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
    try {
      String numPedLimpio = (pedido['numero_pedido']?.toString() ?? 'pedido').replaceAll('#', '').replaceAll(' ', '_');
      final ruta = '${directorio!.path}/Nota_$numPedLimpio.pdf';
      final archivo = File(ruta);
      await archivo.writeAsBytes(await pdf.save());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PDF guardado en Descargas: Nota_$numPedLimpio.pdf')),
      );
      await Printing.layoutPdf(onLayout: (format) async => pdf.save());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al generar el PDF: $e')),
      );
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_mostrarArchivados ? 'Pedidos Archivados' : 'Historial de Pedidos'),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(_mostrarArchivados ? Icons.list : Icons.archive, color: Colors.white),
                  tooltip: _mostrarArchivados ? 'Ver pedidos activos' : 'Agrupar y archivar pedidos',
                  onPressed: () {
                    if (_mostrarArchivados) {
                      setState(() => _mostrarArchivados = false);
                    } else {
                      _mostrarDialogoAgruparPedidos();
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_sweep, color: Colors.amberAccent),
                  tooltip: 'Resetear historial de pedidos',
                  onPressed: _confirmarReseteoHistorial,
                ),
              ],
            ),
          ],
        ),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Buscar por cliente o número de pedido...',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      setState(() {
                        _filtro = val.trim();
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _mostrarArchivados ? Colors.amber.shade700 : Colors.indigo.shade50,
                    foregroundColor: _mostrarArchivados ? Colors.white : Colors.indigo,
                  ),
                  icon: Icon(_mostrarArchivados ? Icons.folder_open : Icons.folder_special),
                  label: Text(_mostrarArchivados ? 'Ver Activos' : 'Archivados'),
                  onPressed: () {
                    setState(() {
                      _mostrarArchivados = !_mostrarArchivados;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _obtenerPedidos(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                  final pedidos = snapshot.data!;
                  if (pedidos.isEmpty) {
                    return Center(
                      child: Text(
                        _mostrarArchivados ? 'No hay pedidos archivados o agrupados' : 'No hay pedidos registrados',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: pedidos.length,
                    itemBuilder: (context, index) {
                      final p = pedidos[index];
                       
                      final String numPedido = p['numero_pedido']?.toString() ?? 'Pedido #${p['id']}';
                      final String cliente = p['cliente']?.toString() ?? 'Sin cliente';
                      final String fecha = p['fecha']?.toString() ?? '';
                      final double total = (p['total'] as num?)?.toDouble() ?? 0.0;
                      final String grupo = p['grupo']?.toString() ?? '';
                       
                      String productosJson = p['productos_json']?.toString() ?? '';
                      List<String> listaProductos = productosJson
                          .split(';')
                          .map((prod) => prod.trim())
                          .where((prod) => prod.isNotEmpty)
                          .toList();
                      return Container(
                        width: double.infinity,
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: Card(
                          elevation: 3,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          numPedido,
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.indigo,
                                          ),
                                        ),
                                        if (grupo.isNotEmpty)
                                          Text(
                                            'Bloque: $grupo',
                                            style: const TextStyle(fontSize: 11, color: Colors.amber, fontWeight: FontWeight.bold),
                                          ),
                                      ],
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.picture_as_pdf, color: Colors.indigo, size: 22),
                                          tooltip: 'Generar PDF del Pedido',
                                          onPressed: () => _exportarPdfPedidoIndividual(p),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.edit, color: Colors.blue, size: 22),
                                          onPressed: () => _editarPedido(p),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete, color: Colors.red, size: 22),
                                          onPressed: () => _eliminarPedido(p['id']),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const Divider(height: 16),
                                Text(
                                  cliente,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  'Productos:',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo),
                                ),
                                const SizedBox(height: 4),
                                ...listaProductos.map((prod) => Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Text(
                                    '• $prod',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                )),
                                const Divider(height: 16),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Total: L ${total.toStringAsFixed(2)}',
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green,
                                      ),
                                    ),
                                    Text(
                                      fecha,
                                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
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
    );
  }
}
// ==========================================
// 3. PESTAÑA: GESTIÓN DE CLIENTES
// ==========================================
class VistaGestionClientes extends StatefulWidget {
  const VistaGestionClientes({super.key});
  @override
  State<VistaGestionClientes> createState() => _VistaGestionClientesState();
}
class _VistaGestionClientesState extends State<VistaGestionClientes> {
  bool _cargando = false;
  Future<void> _sincronizar() async {
    setState(() => _cargando = true);
    try {
      final response = await http.get(Uri.parse(urlClientesCSV));
      if (response.statusCode == 200) {
        await DatabaseHelper.instance.sincronizarClientesDesdeCSV(response.body);
        if(!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Clientes sincronizados con éxito')));
      } else {
        throw Exception('Error al descargar CSV');
      }
    } catch (e) {
      if(!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error de sincronización: $e')));
    } finally {
      setState(() => _cargando = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestión de Clientes'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sincronizar desde Google Sheets',
            onPressed: _cargando ? null : _sincronizar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : FutureBuilder<List<Map<String, dynamic>>>(
              future: DatabaseHelper.instance.database.then((db) => db.query('clientes')),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final clientes = snapshot.data!;
                if (clientes.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('No hay clientes. Sincroniza desde Google Sheets.'),
                        const SizedBox(height: 10),
                        ElevatedButton(onPressed: _sincronizar, child: const Text('Sincronizar Ahora'))
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: clientes.length,
                  itemBuilder: (context, index) {
                    final c = clientes[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        title: Text(c['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('Código: ${c['codigo']} | Tel: ${c['telefono']}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.phone, color: Colors.green),
                          onPressed: () async {
                            final Uri launchUri = Uri(scheme: 'tel', path: c['telefono']);
                            if (await canLaunchUrl(launchUri)) {
                              await launchUrl(launchUri);
                            }
                          },
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
// 4. PESTAÑA: GESTIÓN DE PRODUCTOS
// ==========================================
class VistaGestionProductos extends StatefulWidget {
  const VistaGestionProductos({super.key});
  @override
  State<VistaGestionProductos> createState() => _VistaGestionProductosState();
}
class _VistaGestionProductosState extends State<VistaGestionProductos> {
  bool _cargando = false;
  Future<void> _sincronizar() async {
    setState(() => _cargando = true);
    try {
      final response = await http.get(Uri.parse(urlProductosCSV));
      if (response.statusCode == 200) {
        await DatabaseHelper.instance.sincronizarProductosDesdeCSV(response.body);
        if(!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Productos sincronizados con éxito')));
      } else {
        throw Exception('Error al descargar CSV');
      }
    } catch (e) {
      if(!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error de sincronización: $e')));
    } finally {
      setState(() => _cargando = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestión de Productos'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sincronizar desde Google Sheets',
            onPressed: _cargando ? null : _sincronizar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : FutureBuilder<List<Map<String, dynamic>>>(
              future: DatabaseHelper.instance.database.then((db) => db.query('productos')),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final productos = snapshot.data!;
                if (productos.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('No hay productos. Sincroniza desde Google Sheets.'),
                        const SizedBox(height: 10),
                        ElevatedButton(onPressed: _sincronizar, child: const Text('Sincronizar Ahora'))
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: productos.length,
                  itemBuilder: (context, index) {
                    final p = productos[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        title: Text(p['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('Código: ${p['codigo']}'),
                        trailing: Text('L ${(p['precio'] as num).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.indigo)),
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
// 5. PESTAÑA: RESUMEN GENERAL
// ==========================================
class VistaResumenGeneral extends StatefulWidget {
  const VistaResumenGeneral({super.key});
  @override
  State<VistaResumenGeneral> createState() => _VistaResumenGeneralState();
}
class _VistaResumenGeneralState extends State<VistaResumenGeneral> {
  @override
  void initState() {
    super.initState();
    changeNotifierPedidos.addListener(_recargar);
  }
  @override
  void dispose() {
    changeNotifierPedidos.removeListener(_recargar);
    super.dispose();
  }
  void _recargar() {
    if (mounted) setState(() {});
  }
  Future<Map<String, dynamic>> _obtenerResumen() async {
    final db = await DatabaseHelper.instance.database;
    final totalPedidosRes = await db.rawQuery('SELECT COUNT(*) as count, SUM(total) as suma FROM pedidos');
    var resultado = totalPedidosRes.first;
    int count = resultado['count'] as int? ?? 0;
    double suma = (resultado['suma'] as num?)?.toDouble() ?? 0.0;
    return {'count': count, 'suma': suma};
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resumen General'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _obtenerResumen(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final data = snapshot.data!;
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      children: [
                        const Text('Total de Pedidos Realizados', style: TextStyle(fontSize: 16, color: Colors.grey)),
                        const SizedBox(height: 10),
                        Text('${data['count']}', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.indigo)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      children: [
                        const Text('Monto Total Vendido', style: TextStyle(fontSize: 16, color: Colors.grey)),
                        const SizedBox(height: 10),
                        Text('L ${(data['suma'] as double).toStringAsFixed(2)}', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.green)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
// ========================================================================
// PESTAÑA: RESUMEN POR PRODUCTO CON BOTÓN DE EXPORTACIÓN A PDF EN EL APPBAR
// =========================================================================

class VistaResumenPorProducto extends StatefulWidget {
  const VistaResumenPorProducto({Key? key}) : super(key: key);

  @override
  State<VistaResumenPorProducto> createState() => _VistaResumenPorProductoState();
}

class _VistaResumenPorProductoState extends State<VistaResumenPorProducto> {
  List<Map<String, dynamic>> _resumenProductos = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargarResumen();
  }

  Future<void> _cargarResumen() async {
    setState(() => _cargando = true);
    try {
      final db = await DatabaseHelper.instance.database;
      final List<Map<String, dynamic>> resultado = await db.rawQuery('''
        SELECT nombre_producto, SUM(cantidad) AS total_cantidad
        FROM detalle_pedidos
        GROUP BY nombre_producto
        ORDER BY total_cantidad DESC
      ''');

      setState(() {
        _resumenProductos = resultado;
        _cargando = false;
      });
    } catch (e) {
      setState(() => _cargando = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al cargar resumen: $e')),
        );
      }
    }
  }

  // GENERAR Y GUARDAR PDF DEL RESUMEN POR PRODUCTO
  Future<void> _generarPdfResumen() async {
    if (_resumenProductos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay productos para exportar')),
      );
      return;
    }

    try {
      final pdf = pw.Document();
      
      int granTotalUnidades = 0;
      List<List<String>> filas = [];

      for (var item in _resumenProductos) {
        String prod = item['nombre_producto']?.toString() ?? 'Producto';
        int cant = (item['total_cantidad'] as num?)?.toInt() ?? 0;
        granTotalUnidades += cant;
        filas.add([prod, cant.toString()]);
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(24),
          build: (pw.Context context) {
            return [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text("D I C O S M O", style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900)),
                      pw.Text("RESUMEN GENERAL POR PRODUCTO", style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text("Fecha: ${DateFormat('dd/MM/yyyy').format(DateTime.now())}", style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
                      pw.Text("Total Ítems: ${_resumenProductos.length}", style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 12),
              pw.Table.fromTextArray(
                headers: ['Producto / Descripción', 'Cantidad Total Solicitada'],
                data: filas,
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 10),
                headerDecoration: const pw.BoxDecoration(color: PdfColors.blue900),
                cellStyle: const pw.TextStyle(fontSize: 9),
                cellPadding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                columnWidths: {
                  0: const pw.FlexColumnWidth(3.0),
                  1: const pw.FlexColumnWidth(1.0),
                },
                cellAlignments: {
                  0: pw.Alignment.centerLeft,
                  1: pw.Alignment.center,
                },
              ),
              pw.SizedBox(height: 12),
              pw.Container(
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey200,
                  borderRadius: pw.BorderRadius.circular(4),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text("GRAN TOTAL DE UNIDADES:", style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                    pw.Text("$granTotalUnidades unidades", style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900)),
                  ],
                ),
              ),
            ];
          },
        ),
      );

      final bytes = await pdf.save();
      String nombreArchivo = 'Resumen_Por_Producto_${DateTime.now().millisecondsSinceEpoch}.pdf';

      await Printing.sharePdf(bytes: bytes, filename: nombreArchivo);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PDF generado correctamente. Seleccione Guardar en Descargas.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al exportar PDF: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resumen por Producto'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Exportar a PDF',
            onPressed: _generarPdfResumen,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _resumenProductos.isEmpty
              ? const Center(child: Text('No hay productos registrados'))
              : RefreshIndicator(
                  onRefresh: _cargarResumen,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _resumenProductos.length,
                    itemBuilder: (context, index) {
                      final item = _resumenProductos[index];
                      final nombre = item['nombre_producto']?.toString() ?? 'Producto';
                      final total = item['total_cantidad']?.toString() ?? '0';

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          title: Text(
                            nombre,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Total: $total',
                              style: TextStyle(
                                color: Colors.blue.shade900,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

// =============================================================================
// MODELO AUXILIAR PARA AGRUPAR PEDIDOS POR SEMANA
// =============================================================================

class _SemanaModel {
  final String key;
  final DateTime fechaInicio;
  final DateTime fechaFin;
  final String etiqueta;
  final List<int> idsPedidos;

  _SemanaModel({
    required this.key,
    required this.fechaInicio,
    required this.fechaFin,
    required this.etiqueta,
    required this.idsPedidos,
  });
}

// =========================================================================
// PESTAÑA: EXPORTAR REPORTES PDF (FILTRO POR SEMANA Y ENTREGAS)
// =========================================================================

class VistaExportarPdf extends StatefulWidget {
  const VistaExportarPdf({Key? key}) : super(key: key);

  @override
  State<VistaExportarPdf> createState() => _VistaExportarPdfState();
}

class _VistaExportarPdfState extends State<VistaExportarPdf> {
  List<Map<String, dynamic>> _listaPedidos = [];
  List<_SemanaModel> _listaSemanas = [];
  bool _cargandoDatos = true;

  // --- Estado para Reporte De Productos Por Semana ---
  String? _semanaSeleccionadaKey;

  // --- Estado para Gestión de Entregas y Reporte General ---
  final Map<int, Map<String, dynamic>> _entregasProcesadas = {};
  int? _idPedidoSeleccionadoEntrega;

  final TextEditingController _montoEntregadoController = TextEditingController();
  final TextEditingController _comentarioEntregaController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargarPedidos();
  }

  @override
  void dispose() {
    _montoEntregadoController.dispose();
    _comentarioEntregaController.dispose();
    super.dispose();
  }

  DateTime _parseFecha(String? fechaStr) {
    if (fechaStr == null || fechaStr.isEmpty) return DateTime.now();
    try {
      return DateTime.parse(fechaStr);
    } catch (_) {
      try {
        return DateFormat('dd/MM/yyyy').parse(fechaStr);
      } catch (_) {
        return DateTime.now();
      }
    }
  }

  DateTime _inicioSemana(DateTime dt) {
    DateTime d = DateTime(dt.year, dt.month, dt.day);
    return d.subtract(Duration(days: d.weekday - 1));
  }

  DateTime _finSemana(DateTime inicio) {
    return DateTime(inicio.year, inicio.month, inicio.day, 23, 59, 59).add(const Duration(days: 6));
  }

  Future<void> _cargarPedidos() async {
    setState(() => _cargandoDatos = true);
    try {
      final db = await DatabaseHelper.instance.database;
      final List<Map<String, dynamic>> pedidos = await db.rawQuery('''
        SELECT 
          p.id, 
          p.numero_pedido, 
          p.cliente, 
          p.total, 
          p.fecha,
          c.codigo AS codigo_cliente
        FROM pedidos p
        LEFT JOIN clientes c ON p.cliente = c.nombre
        ORDER BY p.id ASC
      ''');

      // Agrupar pedidos por semana
      Map<String, _SemanaModel> mapaSemanas = {};

      for (var p in pedidos) {
        int id = p['id'] as int;
        DateTime f = _parseFecha(p['fecha']?.toString());
        DateTime inicio = _inicioSemana(f);
        DateTime fin = _finSemana(inicio);

        String key = DateFormat('yyyy-MM-dd').format(inicio);
        String etiqueta = "Semana del ${DateFormat('dd/MM/yyyy').format(inicio)} al ${DateFormat('dd/MM/yyyy').format(fin)}";

        if (!mapaSemanas.containsKey(key)) {
          mapaSemanas[key] = _SemanaModel(
            key: key,
            fechaInicio: inicio,
            fechaFin: fin,
            etiqueta: etiqueta,
            idsPedidos: [id],
          );
        } else {
          mapaSemanas[key]!.idsPedidos.add(id);
        }
      }

      List<_SemanaModel> listaSemanas = mapaSemanas.values.toList();
      listaSemanas.sort((a, b) => b.fechaInicio.compareTo(a.fechaInicio));

      setState(() {
        _listaPedidos = pedidos;
        _listaSemanas = listaSemanas;
        _cargandoDatos = false;
      });
    } catch (e) {
      setState(() => _cargandoDatos = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al cargar pedidos: $e')),
        );
      }
    }
  }

  // --- LÓGICA DE GESTIÓN DE ENTREGAS ---
  void _alSeleccionarPedidoEntrega(int? idPedido) {
    if (idPedido == null) {
      setState(() {
        _idPedidoSeleccionadoEntrega = null;
        _montoEntregadoController.clear();
        _comentarioEntregaController.clear();
      });
      return;
    }

    final pedido = _listaPedidos.firstWhere(
      (p) => p['id'] == idPedido,
      orElse: () => {},
    );

    if (pedido.isNotEmpty) {
      double total = (pedido['total'] as num?)?.toDouble() ?? 0.0;

      if (_entregasProcesadas.containsKey(idPedido)) {
        _montoEntregadoController.text =
            _entregasProcesadas[idPedido]!['entregado'].toString();
        _comentarioEntregaController.text =
            _entregasProcesadas[idPedido]!['comentario'] ?? '';
      } else {
        _montoEntregadoController.text = total.toStringAsFixed(2);
        _comentarioEntregaController.clear();
      }

      setState(() {
        _idPedidoSeleccionadoEntrega = idPedido;
      });
    }
  }

  void _guardarDatosEntrega() {
    if (_idPedidoSeleccionadoEntrega == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor, seleccione un pedido')),
      );
      return;
    }

    double valEntregado = double.tryParse(_montoEntregadoController.text) ?? 0.0;
    String comentario = _comentarioEntregaController.text.trim();

    setState(() {
      _entregasProcesadas[_idPedidoSeleccionadoEntrega!] = {
        'entregado': valEntregado,
        'comentario': comentario,
      };
      _idPedidoSeleccionadoEntrega = null;
      _montoEntregadoController.clear();
      _comentarioEntregaController.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('¡Datos del pedido guardados exitosamente!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  // COMPARTIR / GUARDAR PDF EN DISPOSITIVO
  Future<void> _guardarYCompartirPdf(pw.Document pdf, String nombreArchivo) async {
    try {
      final bytes = await pdf.save();
      final outputDir = await getTemporaryDirectory();
      final file = File('${outputDir.path}/$nombreArchivo');
      await file.writeAsBytes(bytes);

      await Printing.sharePdf(bytes: bytes, filename: nombreArchivo);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al exportar PDF: $e')),
      );
    }
  }

  // 1. REPORTE DE PRODUCTOS POR SEMANA (PDF)
  Future<void> _generarPdfReporteProductosPorSemana() async {
    if (_semanaSeleccionadaKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccione una semana para generar el reporte')),
      );
      return;
    }

    final semana = _listaSemanas.firstWhere(
      (s) => s.key == _semanaSeleccionadaKey,
      orElse: () => _SemanaModel(
        key: '',
        fechaInicio: DateTime.now(),
        fechaFin: DateTime.now(),
        etiqueta: '',
        idsPedidos: [],
      ),
    );

    if (semana.idsPedidos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay pedidos registrados en esta semana')),
      );
      return;
    }

    final db = await DatabaseHelper.instance.database;
    String placeholders = List.filled(semana.idsPedidos.length, '?').join(',');
    
    final List<Map<String, dynamic>> detalles = await db.rawQuery('''
      SELECT 
        nombre_producto, 
        SUM(cantidad) AS total_cantidad,
        SUM(subtotal) AS total_subtotal
      FROM detalle_pedidos
      WHERE pedido_id IN ($placeholders)
      GROUP BY nombre_producto
      ORDER BY total_cantidad DESC
    ''', semana.idsPedidos);

    if (!mounted) return;

    double totalGeneralMonto = 0.0;
    int totalGeneralCantidad = 0;
    List<List<String>> filasTabla = [];

    for (var d in detalles) {
      String prod = d['nombre_producto']?.toString() ?? 'Producto';
      int cant = (d['total_cantidad'] as num?)?.toInt() ?? 0;
      double subtotal = (d['total_subtotal'] as num?)?.toDouble() ?? 0.0;

      totalGeneralCantidad += cant;
      totalGeneralMonto += subtotal;

      filasTabla.add([
        prod,
        cant.toString(),
        'L. ${subtotal.toStringAsFixed(2)}',
      ]);
    }

    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(24),
        build: (pw.Context context) {
          return [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text("D I C O S M O", style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900)),
                    pw.Text("REPORTE DE PRODUCTOS POR SEMANA", style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text("Fecha Gen.: ${DateFormat('dd/MM/yyyy').format(DateTime.now())}", style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
                    pw.Text("Pedidos en Semana: ${semana.idsPedidos.length}", style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey200,
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text("Rango: ${semana.etiqueta}", style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                  pw.Text("Monto Total: L. ${totalGeneralMonto.toStringAsFixed(2)}", style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900)),
                ],
              ),
            ),
            pw.SizedBox(height: 12),
            pw.Table.fromTextArray(
              headers: ['Producto / Descripción', 'Cantidad Total', 'Monto Total'],
              data: filasTabla,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 9),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blue900),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              columnWidths: {
                0: const pw.FlexColumnWidth(3.0),
                1: const pw.FlexColumnWidth(1.2),
                2: const pw.FlexColumnWidth(1.5),
              },
              cellAlignments: {
                0: pw.Alignment.centerLeft,
                1: pw.Alignment.center,
                2: pw.Alignment.centerRight,
              },
            ),
            pw.SizedBox(height: 12),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Text(
                "Total Unidades: $totalGeneralCantidad | Total Valor: L. ${totalGeneralMonto.toStringAsFixed(2)}",
                style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900),
              ),
            ),
          ];
        },
      ),
    );

    String nombre = 'Reporte_Productos_${semana.key}_${DateTime.now().millisecondsSinceEpoch}.pdf';
    await _guardarYCompartirPdf(pdf, nombre);
  }

  // 2. REPORTE GENERAL POR CLIENTE (PDF CONSOLIDADOR)
  Future<void> _generarPdfReporteGeneralPorCliente() async {
    if (_listaPedidos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay pedidos registrados para generar el reporte')),
      );
      return;
    }

    List<List<String>> filasReporte = [];
    double sumaTotalPedidos = 0.0;
    double sumaTotalEntregado = 0.0;

    for (var p in _listaPedidos) {
      int idPedido = p['id'] as int;
      String nombreCliente = p['cliente']?.toString() ?? '';
      String codigoCliente = p['codigo_cliente']?.toString() ?? '';
      String clienteConCodigo = codigoCliente.isNotEmpty ? '[$codigoCliente] $nombreCliente' : nombreCliente;

      String numPedRaw = p['numero_pedido']?.toString() ?? '';
      if (numPedRaw.isEmpty) {
        numPedRaw = 'Pedido #$idPedido';
      } else if (!numPedRaw.toLowerCase().contains('pedido')) {
        numPedRaw = 'Pedido $numPedRaw';
      }

      double totalPedido = (p['total'] as num?)?.toDouble() ?? 0.0;
      sumaTotalPedidos += totalPedido;

      double valEntregado = totalPedido;
      String comentario = 'Entregado';

      if (_entregasProcesadas.containsKey(idPedido)) {
        valEntregado = _entregasProcesadas[idPedido]!['entregado'] ?? totalPedido;
        comentario = _entregasProcesadas[idPedido]!['comentario'] ?? '';
      }

      sumaTotalEntregado += valEntregado;

      filasReporte.add([
        numPedRaw,
        clienteConCodigo,
        'L. ${totalPedido.toStringAsFixed(2)}',
        'L. ${valEntregado.toStringAsFixed(2)}',
        comentario.isEmpty ? '-' : comentario,
      ]);
    }

    double diferenciaTotal = sumaTotalPedidos - sumaTotalEntregado;
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(24),
        build: (pw.Context context) {
          return [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      "D I C O S M O",
                      style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900),
                    ),
                    pw.Text(
                      "PRODUCTOS CHAMER MEDICAMENTOS UTILES ESCOLARES NOVEDADES Y MAS",
                      style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
                    ),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      "REPORTE GRAL POR CLIENTE",
                      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
                    ),
                    pw.Text(
                      "Fecha: ${DateFormat('dd/MM/yy').format(DateTime.now())}",
                      style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 8),

            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.end,
              children: [
                _buildMetricBadge('Total Pedido:', sumaTotalPedidos),
                pw.SizedBox(width: 6),
                _buildMetricBadge('Total Entregado:', sumaTotalEntregado),
                pw.SizedBox(width: 6),
                _buildMetricBadge('Diferencia:', diferenciaTotal),
              ],
            ),
            pw.SizedBox(height: 8),
            pw.Divider(thickness: 1, color: PdfColors.blue900),
            pw.SizedBox(height: 8),

            pw.Table.fromTextArray(
              headers: ['Pedido #', 'Cliente', 'Total Pedido', 'Total Entregado', 'Comentario'],
              data: filasReporte,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 9),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blue900),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              columnWidths: {
                0: const pw.FlexColumnWidth(1.2),
                1: const pw.FlexColumnWidth(2.5),
                2: const pw.FlexColumnWidth(1.4),
                3: const pw.FlexColumnWidth(1.4),
                4: const pw.FlexColumnWidth(2.0),
              },
              cellAlignments: {
                0: pw.Alignment.center,
                1: pw.Alignment.centerLeft,
                2: pw.Alignment.centerRight,
                3: pw.Alignment.centerRight,
                4: pw.Alignment.centerLeft,
              },
            ),
          ];
        },
      ),
    );

    String nombre = 'Reporte_General_Por_Cliente_${DateTime.now().millisecondsSinceEpoch}.pdf';
    await _guardarYCompartirPdf(pdf, nombre);
  }

  pw.Widget _buildMetricBadge(String title, double amount) {
    return pw.Row(
      children: [
        pw.Text(title, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(width: 2),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey700),
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Text('L. ${amount.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> pedidosFaltantes = _listaPedidos.where((p) {
      int id = p['id'] as int;
      return !_entregasProcesadas.containsKey(id) || id == _idPedidoSeleccionadoEntrega;
    }).toList();

    Map<String, dynamic> pedidoActualEntrega = {};
    if (_idPedidoSeleccionadoEntrega != null) {
      pedidoActualEntrega = _listaPedidos.firstWhere(
        (p) => p['id'] == _idPedidoSeleccionadoEntrega,
        orElse: () => {},
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Exportar Reportes PDF'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
      ),
      body: _cargandoDatos
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                // -------------------------------------------------------------
                // CARD 1: REPORTE DE PRODUCTOS POR SEMANA
                // -------------------------------------------------------------
                Card(
                  elevation: 3,
                  margin: const EdgeInsets.only(bottom: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Reporte De Productos Por Semana',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Seleccione una semana para exportar el consolidado de productos con sus cantidades totales.',
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                        const SizedBox(height: 16),

                        DropdownButtonFormField<String>(
                          value: _semanaSeleccionadaKey,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Seleccionar Semana',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          hint: Text(
                            _listaSemanas.isEmpty
                                ? 'No hay semanas con pedidos'
                                : 'Elija una semana de la lista',
                          ),
                          items: _listaSemanas.map((semana) {
                            return DropdownMenuItem<String>(
                              value: semana.key,
                              child: Text(
                                '${semana.etiqueta} (${semana.idsPedidos.length} pedidos)',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _semanaSeleccionadaKey = val;
                            });
                          },
                        ),
                        const SizedBox(height: 16),

                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue.shade900,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: _generarPdfReporteProductosPorSemana,
                            icon: const Icon(Icons.picture_as_pdf),
                            label: const Text('Generar Reporte por Semana'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // -------------------------------------------------------------
                // CARD 2: GESTIÓN DE ENTREGAS Y REPORTE GENERAL POR CLIENTE
                // -------------------------------------------------------------
                Card(
                  elevation: 3,
                  margin: const EdgeInsets.only(bottom: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Reporte General por Cliente',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'Procesados: ${_entregasProcesadas.length} / ${_listaPedidos.length}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue.shade900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Seleccione los pedidos faltantes para actualizar sus valores de entrega y comentarios antes de generar el reporte consolidado.',
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                        const SizedBox(height: 16),

                        // Selector de pedidos faltantes de entrega
                        DropdownButtonFormField<int>(
                          value: _idPedidoSeleccionadoEntrega,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Pedidos Faltantes de Entrega',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          hint: Text(
                            pedidosFaltantes.isEmpty
                                ? '¡Todos los pedidos han sido procesados!'
                                : 'Seleccione un pedido pendiente',
                          ),
                          items: pedidosFaltantes.map((p) {
                            int id = p['id'] as int;
                            String numPed = p['numero_pedido']?.toString() ?? 'Pedido #$id';
                            String cliente = p['cliente']?.toString() ?? '';
                            String cod = p['codigo_cliente']?.toString() ?? '';
                            String labelCliente = cod.isNotEmpty ? '[$cod] $cliente' : cliente;

                            return DropdownMenuItem<int>(
                              value: id,
                              child: Text(
                                '$numPed - $labelCliente',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: _alSeleccionarPedidoEntrega,
                        ),
                        const SizedBox(height: 16),

                        // VISTA DE LECTURA DE DATOS + CAJAS EDITABLES
                        if (pedidoActualEntrega.isNotEmpty) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Datos Visuales del Pedido (Solo Lectura):',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '• Pedido #: ${pedidoActualEntrega['numero_pedido'] ?? "Pedido #${pedidoActualEntrega['id']}"}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                Text(
                                  '• Cliente: ${pedidoActualEntrega['codigo_cliente'] != null && pedidoActualEntrega['codigo_cliente'].toString().isNotEmpty ? "[${pedidoActualEntrega['codigo_cliente']}] " : ""}${pedidoActualEntrega['cliente'] ?? ""}',
                                  style: const TextStyle(fontSize: 14),
                                ),
                                Text(
                                  '• Valor Total del Pedido: L. ${((pedidoActualEntrega['total'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(2)}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue.shade900,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          // CAJA EDITABLE: VALOR ENTREGADO
                          TextField(
                            controller: _montoEntregadoController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Valor Total Entregado (L.)',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.attach_money),
                              helperText: 'Modifique si el cliente entregó un monto distinto',
                            ),
                          ),
                          const SizedBox(height: 12),

                          // CAJA EDITABLE: COMENTARIOS
                          TextField(
                            controller: _comentarioEntregaController,
                            maxLines: 2,
                            decoration: const InputDecoration(
                              labelText: 'Comentario / Novedad de Entrega',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.comment),
                              hintText: 'Ej: Entregado incompleto, pago pendiente, etc.',
                            ),
                          ),
                          const SizedBox(height: 12),

                          // BOTÓN GUARDAR DATOS DEL PEDIDO
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade800,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: _guardarDatosEntrega,
                              icon: const Icon(Icons.save),
                              label: const Text('Guardar Datos del Pedido'),
                            ),
                          ),
                          const Divider(height: 32, thickness: 1),
                        ],

                        // BOTÓN REPORTE GENERAL CONSOLIDADOR
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue.shade900,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: _generarPdfReporteGeneralPorCliente,
                            icon: const Icon(Icons.picture_as_pdf),
                            label: const Text('Generar Reporte General Por Cliente'),
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
