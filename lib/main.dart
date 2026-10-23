import 'package:flutter/material.dart';
import 'database_helper.dart';

// Importación de las 7 vistas modularizadas
import 'views/crear_pedido.dart';
import 'views/historial_pedidos.dart';
import 'views/gestion_clientes.dart';
import 'views/gestion_productos.dart';
import 'views/resumen_general.dart';
import 'views/resumen_productos.dart';
import 'views/exportar_pdf.dart';

// URLs globales usando 'final' para evitar errores de compilación
final String urlClientesCSV = "https://docs.google.com/spreadsheets/d/e/2PACX-1vTmtKhEE5ziDtm_BQdAoEy8c-Z6H6_GbyKcPOvtdjfKtXgxYObBUB-P1K0IdsiwrW78aabDzei-R2Cd/pub?gid=0&single=true&output=csv";
final String urlProductosCSV = "https://docs.google.com/spreadsheets/d/e/2PACX-1vTmtKhEE5ziDtm_BQdAoEy8c-Z6H6_GbyKcPOvtdjfKtXgxYObBUB-P1K0IdsiwrW78aabDzei-R2Cd/pub?gid=1903712481&single=true&output=csv";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper.instance.database;
  runApp(const VentasHobApp());
}

class VentasHobApp extends StatelessWidget {
  const VentasHobApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ventas Hob',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.indigo,
      ),
      home: const MenuPrincipal(),
    );
  }
}

class MenuPrincipal extends StatefulWidget {
  const MenuPrincipal({Key? key}) : super(key: key);

  @override
  State<MenuPrincipal> createState() => MenuPrincipalState();
}

class MenuPrincipalState extends State<MenuPrincipal> {
  int currentIndex = 0;

  // Variables globales para la gestión de pedidos en curso y edición
  String? clienteEnCurso;
  List<Map<String, dynamic>> productosEnCurso = [];
  int? editandoPedidoId;
  String? editandoNumeroPedidoFijo;

  void limpiarPedidoEnCurso() {
    setState(() {
      clienteEnCurso = null;
      productosEnCurso.clear();
      editandoPedidoId = null;
      editandoNumeroPedidoFijo = null;
    });
  }

  // Lista con los nombres de clases estandarizados con 'Vista'
  final List<Widget> _vistas = [
    const VistaCrearPedido(),
    const VistaHistorialPedidos(),
    const VistaGestionClientes(),
    const VistaGestionProductos(),
    const VistaResumenGeneral(),
    const VistaResumenProductos(),
    const VistaExportarPdf(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _vistas[currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: currentIndex,
        onTap: (index) {
          setState(() {
            currentIndex = index;
          });
        },
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.shopping_cart), label: 'Crear'),
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
