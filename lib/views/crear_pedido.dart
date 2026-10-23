import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';
// Asegúrate de que la ruta a tu database_helper y a tu main (donde vive MenuPrincipalState) sea la correcta:
import '../database_helper.dart'; 
import '../main.dart'; 

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
        const SnackBar(content: Text('Buscar Cliente')),
      );
      return;
    }
    if (mainState == null || mainState.productosEnCurso.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Buscar Producto')),
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
          decoration: const InputDecoration(labelText: 'Detalle'),
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
                  color: Colors.indigo.shade50.withOpacity(0.5)
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, color: Colors.indigo),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        mainState?.clienteEnCurso ?? 'Seleccionar Cliente',
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
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Agregar Producto',
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
