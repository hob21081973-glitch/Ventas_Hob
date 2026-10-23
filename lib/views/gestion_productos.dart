import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../database_helper.dart';

class VistaGestionProductos extends StatefulWidget {
  const VistaGestionProductos({super.key});
  
  @override
  State<VistaGestionProductos> createState() => _VistaGestionProductosState();
}

class _VistaGestionProductosState extends State<VistaGestionProductos> {
  bool sincronizando = false;

  const String urlProductosCSV = "https://docs.google.com/spreadsheets/d/e/2PACX-1vTmtKhEE5ziDtm_BQdAeOy8c-Z6H6_GbyKcPOvtdjfKtXgxYObBUB-PlK0ldsiwrW78aabDzei-R2Cd/pub?gid=1903712481&single=true&output=csv";
  
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
            itemBuilder: (context, i) {
              final prod = lista[i];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '[${prod['codigo']}] ${prod['nombre']}', 
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Precio: L ${(prod['precio'] as num).toStringAsFixed(2)}', 
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.indigo),
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
