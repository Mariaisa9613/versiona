import 'package:flutter/material.dart';

void main() {
  runApp(const VersionaApp());
}

class VersionaApp extends StatelessWidget {
  const VersionaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Versiona',
      themeMode: ThemeMode.light,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C8EFF),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8FC),
        useMaterial3: true,
      ),
      home: const DocumentListScreen(),
    );
  }
}

class DocumentVersion {
  final int number;
  final String author;
  final String date;
  final String message;

  const DocumentVersion({
    required this.number,
    required this.author,
    required this.date,
    required this.message,
  });
}

class Document {
  final String name;
  final IconData icon;
  final List<DocumentVersion> versions;

  Document({required this.name, required this.icon, required this.versions});

  DocumentVersion get latest => versions.last;
}

class DocumentListScreen extends StatefulWidget {
  const DocumentListScreen({super.key});

  @override
  State<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends State<DocumentListScreen> {
  final List<Document> _documents = [
    Document(
      name: 'Informe anual.docx',
      icon: Icons.description_outlined,
      versions: [
        const DocumentVersion(
          number: 1,
          author: 'Ana Torres',
          date: '2026-06-02',
          message: 'Versión inicial del informe',
        ),
        const DocumentVersion(
          number: 2,
          author: 'Luis Gómez',
          date: '2026-06-18',
          message: 'Corrección de cifras del tercer trimestre',
        ),
        const DocumentVersion(
          number: 3,
          author: 'Ana Torres',
          date: '2026-07-05',
          message: 'Añadidos gráficos y conclusiones',
        ),
      ],
    ),
    Document(
      name: 'Presupuesto 2026.xlsx',
      icon: Icons.table_chart_outlined,
      versions: [
        const DocumentVersion(
          number: 1,
          author: 'María López',
          date: '2026-01-10',
          message: 'Primera propuesta de presupuesto',
        ),
        const DocumentVersion(
          number: 2,
          author: 'María López',
          date: '2026-03-22',
          message: 'Ajuste de partidas de marketing',
        ),
      ],
    ),
    Document(
      name: 'Contrato proveedor.pdf',
      icon: Icons.picture_as_pdf_outlined,
      versions: [
        const DocumentVersion(
          number: 1,
          author: 'Carlos Ruiz',
          date: '2026-05-14',
          message: 'Borrador enviado a legal',
        ),
      ],
    ),
  ];

  void _addDocument() {
    final index = _documents.length + 1;
    setState(() {
      _documents.add(
        Document(
          name: 'Documento nuevo $index.docx',
          icon: Icons.insert_drive_file_outlined,
          versions: [
            DocumentVersion(
              number: 1,
              author: 'Tú',
              date: DateTime.now().toString().split(' ').first,
              message: 'Versión inicial',
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Versiona'),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _documents.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final document = _documents[index];
          return ListTile(
            leading: CircleAvatar(
              child: Icon(document.icon),
            ),
            title: Text(document.name),
            subtitle: Text(
              'v${document.latest.number} · ${document.latest.date}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => VersionHistoryScreen(document: document),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addDocument,
        tooltip: 'Nuevo documento',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class VersionHistoryScreen extends StatelessWidget {
  final Document document;

  const VersionHistoryScreen({super.key, required this.document});

  @override
  Widget build(BuildContext context) {
    final versions = document.versions.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(document.name),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: versions.length,
        itemBuilder: (context, index) {
          final version = versions[index];
          final isLatest = index == 0;

          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: isLatest
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Text(
                        'v${version.number}',
                        style: TextStyle(
                          fontSize: 11,
                          color: isLatest
                              ? Theme.of(context).colorScheme.onPrimary
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (index != versions.length - 1)
                      Container(
                        width: 2,
                        height: 48,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            version.message,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${version.author} · ${version.date}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
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
