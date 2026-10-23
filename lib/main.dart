import 'package:flutter/material.dart';
import 'database_helper.dart';

// Importación de las 7 vistas modularizadas dentro de la carpeta views/
import 'views/crear_pedido.dart';
import 'views/historial_pedidos.dart';
import 'views/gestion_clientes.dart';
import 'views/gestion_productos.dart';
import 'views/resumen_general.dart';
import 'views/resumen_productos.dart';
import 'views/exportar_pdf.dart';

// URLs globales para la sincronización por CSV
final String urlClientesCSV = "https://docs.google.com/spreadsheets/d/e/2PACX-1vTmtKhEE5ziDtm_BQdAeOy8c-Z6H6_GbyKcPOvtdjfKtXgxYObBUB-PlK0ldsiwrW78aabDzei-R2Cd/pub?gid=0&single=true&output=csv";
final String urlProductosCSV = "https://docs.google.com/spreadsheets/d/e/2PACX-1vTmtKhEE5ziDtm_BQdAeOy8c-Z6H6_GbyKcPOvtdjfKtXgxYObBUB-PlK0ldsiwrW78aabDzei-R2Cd/pub?gid=1903712481&single=true&output=csv";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper.instance.database;
  runApp(const VentasHobApp());
}

class VentasHobApp extends StatelessWidget {
  const VentasHobApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ventas Hob',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
      ),
      home: const MenuPrincipal(),
    );
  }
}

class MenuPrincipal extends StatefulWidget {
  const MenuPrincipal({super.key});

  @override
  State<MenuPrincipal> createState() => MenuPrincipalState();
}

class MenuPrincipalState extends State<MenuPrincipal> {
  int _indiceActual = 0;

  // Estado global compartido por las pestañas de pedidos
  String? clienteEnCurso;
  List<Map<String, dynamic>> productosEnCurso = [];
  
  // Variables para control de edición de pedidos existentes
  int? editandoPedidoId;
  String? editandoNumeroPedidoFijo;

  // Lista de las 7 pestañas oficiales de la aplicación
  final List<Widget> _vistas = [
    const VistaCrearPedido(),
    const VistaHistorialPedidos(),
    const VistaGestionClientes(),
    const VistaGestionProductos(),
    const VistaResumenGeneral(),
    const VistaResumenProductos(),
    const VistaExportarPdf(),
  ];

  void limpiarPedidoEnCurso() {
    setState(() {
      clienteEnCurso = null;
      productosEnCurso.clear();
      editandoPedidoId = null;
      editandoNumeroPedidoFijo = null;
    });
  }

  void cargarPedidoParaEditar(int id, String numeroPedido, String cliente, List<Map<String, dynamic>> productos) {
    setState(() {
      editandoPedidoId = id;
      editandoNumeroPedidoFijo = numeroPedido;
      clienteEnCurso = cliente;
      productosEnCurso = productos;
      _indiceActual = 0; // Mover automáticamente a la pestaña "Crear Pedido" para editar
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _indiceActual,
        children: _vistas,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _indiceActual,
        onTap: (index) {
          setState(() {
            _indiceActual = index;
          });
        },
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.indigo,
        selectedItemColor: Colors.amberAccent,
        unselectedItemColor: Colors.white70,
        selectedFontSize: 11,
        unselectedFontSize: 10,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.add_shopping_cart), label: 'Crear'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'Historial'),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Clientes'),
          BottomNavigationBarItem(icon: Icon(Icons.inventory), label: 'Productos'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'Resumen'),
          BottomNavigationBarItem(icon: Icon(Icons.pie_chart), label: 'Por Prod.'),
          BottomNavigationBarItem(icon: Icon(Icons.picture_as_pdf), label: 'Exportar'),
        ],
      ),
    );
  }
}
