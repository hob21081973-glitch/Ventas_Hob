import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../database_helper.dart';

class VistaGestionClientes extends StatefulWidget {
  const VistaGestionClientes({super.key});

  @override
  State<VistaGestionClientes> createState() => _VistaGestionClientesState();
}

class _VistaGestionClientesState extends State<VistaGestionClientes> {
  bool sincronizando = false;

  // URL del CSV de clientes (asegúrate de que esté definida en tu main.dart o configúrala aquí directamente si la requieres)
  // final String urlClientesCSV = "https://docs.google.com/spreadsheets/d/e/2PACX-1vTmtKhEE5ziDtm_BQdAeOy8c-Z6H6_GbyKcPOvtdjfKtXgxYObBUB-PlK0ldsiwrW78aabDzei-R2Cd/pub?gid=0&single=true&output=csv"; 

  Future<void> _sincronizar() async {
    setState(() => sincronizando = true);
    try {
      // Nota: Si urlClientesCSV está declarada en main.dart y la quieres usar globalmente, 
      // puedes importarla o pasarla. Aquí asumimos que la variable existe en tu entorno.
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
