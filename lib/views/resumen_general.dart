import 'package:flutter/material.dart';
import '../database_helper.dart';

class VistaResumenGeneral extends StatelessWidget {
  const VistaResumenGeneral({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resumen General'), 
        backgroundColor: Colors.indigo, 
        foregroundColor: Colors.white,
      ),
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
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Venta Total General: L ${totalGlobal.toStringAsFixed(2)}', 
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Divider(),
              const Text('Ventas por Fecha:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 6),
              ...porFecha.entries.map((e) => Card(
                margin: const EdgeInsets.symmetric(vertical: 3),
                child: ListTile(
                  dense: true,
                  title: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w500)), 
                  trailing: Text('L ${e.value.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo)),
                ),
              )),
              const SizedBox(height: 10),
              const Divider(),
              const Text('Ventas por Cliente:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 6),
              ...porCliente.entries.map((e) => Card(
                margin: const EdgeInsets.symmetric(vertical: 3),
                child: ListTile(
                  dense: true,
                  title: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w500)), 
                  trailing: Text('L ${e.value.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo)),
                ),
              )),
            ],
          );
        },
      ),
    );
  }
}
