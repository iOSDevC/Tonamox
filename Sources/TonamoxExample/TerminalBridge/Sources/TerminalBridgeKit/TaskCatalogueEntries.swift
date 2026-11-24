import Foundation

/// The macOS/zsh catalogue. Flags were checked against the BSD man pages of macOS 27.2.
public enum TaskCatalogue {
    public static let macOS: [CatalogueTask] = disk + network + processes + system + files + git + homebrew
        + archives

    public static func task(_ id: String) -> CatalogueTask? {
        macOS.first { $0.id == id }
    }

    // MARK: Building blocks

    private static func word(_ text: String) -> CatalogueWord { .literal(text) }
    private static func value(_ id: String) -> CatalogueWord { .parameter(id) }

    private static func words(_ texts: String...) -> [CatalogueWord] {
        texts.map(CatalogueWord.literal)
    }

    private static func run(_ stages: [CatalogueWord]...) -> [CatalogueTaskVariant] {
        [CatalogueTaskVariant(id: "run", title: "Ejecutar", role: .readOnly, stages: stages)]
    }

    private static let folder = CatalogueParameter(id: "path", label: "Carpeta", kind: .path, example: "~/Downloads")
    private static let file = CatalogueParameter(id: "path", label: "Archivo", kind: .path, example: "notas.txt")
    private static let archive = CatalogueParameter(
        id: "path", label: "Archivo comprimido", kind: .path, example: "copia.tar"
    )
    private static func count(_ label: String, _ range: ClosedRange<Int>, example: String) -> CatalogueParameter {
        CatalogueParameter(id: "count", label: label, kind: .count(range), example: example)
    }
    private static let processName = CatalogueParameter(
        id: "name", label: "Nombre del proceso", kind: .processName, example: "Safari"
    )

    // MARK: Disk

    private static let disk: [CatalogueTask] = [
        CatalogueTask(
            id: "disk.free", title: "Espacio libre",
            summary: "Tamaño, uso y espacio libre de cada volumen montado.",
            category: .disk, variants: run(words("df", "-h"))
        ),
        CatalogueTask(
            id: "disk.folderSize", title: "Tamaño de una carpeta",
            summary: "Cuánto ocupa una carpeta con todo su contenido.",
            category: .disk, parameters: [folder], variants: run(words("du", "-sh") + [value("path")])
        ),
        CatalogueTask(
            id: "disk.largestEntries", title: "Lo que más ocupa en una carpeta",
            summary: "Los archivos y carpetas más grandes dentro de una carpeta, de mayor a menor.",
            category: .disk, parameters: [folder, count("Cuántos mostrar", 1...100, example: "10")],
            variants: run(
                words("du", "-ah") + [value("path")],
                words("sort", "-rh"),
                words("head", "-n") + [value("count")]
            )
        ),
        CatalogueTask(
            id: "disk.bigFiles", title: "Archivos grandes",
            summary: "Archivos de una carpeta que superan un tamaño en megabytes.",
            category: .disk, parameters: [folder, count("Tamaño mínimo (MB)", 1...100_000, example: "500")],
            variants: run(
                [word("find"), value("path")] + words("-type", "f", "-size")
                    + [CatalogueWord([.literal("+"), .parameter("count"), .literal("M")])]
            )
        ),
    ]

    // MARK: Network

    private static let network: [CatalogueTask] = [
        CatalogueTask(
            id: "network.portListener", title: "Quién escucha en un puerto",
            summary: "El proceso que acepta conexiones TCP en un puerto local.",
            category: .network,
            parameters: [CatalogueParameter(id: "port", label: "Puerto", kind: .port, example: "8080")],
            variants: run(
                words("lsof", "-nP") + [CatalogueWord([.literal("-iTCP:"), .parameter("port")]), word("-sTCP:LISTEN")]
            )
        ),
        CatalogueTask(
            id: "network.localAddress", title: "Dirección IP local",
            summary: "La dirección IPv4 de una interfaz de red; vacía si no está conectada.",
            category: .network,
            parameters: [CatalogueParameter(
                id: "interface", label: "Interfaz",
                kind: .choice([
                    CatalogueChoice(value: "en0", title: "en0 (Wi-Fi o Ethernet principal)"),
                    CatalogueChoice(value: "en1", title: "en1 (segunda interfaz)"),
                ]),
                example: "en0"
            )],
            variants: run(words("ipconfig", "getifaddr") + [value("interface")])
        ),
        CatalogueTask(
            id: "network.ping", title: "Comprobar si un equipo responde",
            summary: "Envía unos pocos paquetes ping y muestra el tiempo de respuesta.",
            category: .network,
            parameters: [
                CatalogueParameter(id: "host", label: "Equipo", kind: .host, example: "example.com"),
                count("Paquetes", 1...20, example: "4"),
            ],
            variants: run(words("ping", "-c") + [value("count"), value("host")])
        ),
        CatalogueTask(
            id: "network.httpHeaders", title: "Cabeceras de una web",
            summary: "Pide solo las cabeceras HTTP de una dirección, sin descargar la página.",
            category: .network,
            parameters: [CatalogueParameter(id: "url", label: "Dirección", kind: .url, example: "https://example.com")],
            // -g: curl itself expands [1-9999] and {a,b} in a URL into many requests.
            variants: run(words("curl", "-g", "-I") + [value("url")])
        ),
    ]

    // MARK: Processes

    private static let processes: [CatalogueTask] = [
        CatalogueTask(
            id: "processes.find", title: "Buscar procesos",
            summary: "Procesos cuya orden completa contiene un texto, con su número.",
            category: .processes, parameters: [processName],
            variants: run(words("pgrep", "-fl", "--") + [value("name")])
        ),
        CatalogueTask(
            id: "processes.terminate", title: "Terminar un proceso por nombre",
            summary: "Muestra y después termina los procesos con ese nombre exacto.",
            category: .processes, parameters: [processName],
            variants: [
                CatalogueTaskVariant(
                    id: "preview", title: "Ver cuáles", role: .preview,
                    stages: [words("pgrep", "-lx", "--") + [value("name")]]
                ),
                CatalogueTaskVariant(
                    id: "terminate", title: "Terminarlos", role: .destructive,
                    stages: [words("pkill", "-x", "--") + [value("name")]],
                    expectedWarnings: [.killall]
                ),
            ]
        ),
    ]

    // MARK: System

    private static let system: [CatalogueTask] = [
        CatalogueTask(
            id: "system.version", title: "Versión de macOS",
            summary: "Nombre, versión y compilación del sistema.",
            category: .system, variants: run(words("sw_vers"))
        ),
        CatalogueTask(
            id: "system.architecture", title: "Tipo de procesador",
            summary: "arm64 en Apple silicon, x86_64 en Intel.",
            category: .system, variants: run(words("uname", "-m"))
        ),
        CatalogueTask(
            id: "system.memory", title: "Memoria instalada",
            summary: "La memoria física total, en bytes.",
            category: .system, variants: run(words("sysctl", "-n", "hw.memsize"))
        ),
    ]

    // MARK: Files

    private static let files: [CatalogueTask] = [
        CatalogueTask(
            id: "files.findByName", title: "Buscar archivos por nombre",
            summary: "Archivos de una carpeta cuyo nombre coincide; admite * y ?.",
            category: .files,
            parameters: [
                folder,
                CatalogueParameter(id: "name", label: "Nombre", kind: .fileName, example: "*.pdf"),
            ],
            variants: run([word("find"), value("path")] + words("-type", "f", "-name") + [value("name")])
        ),
        CatalogueTask(
            id: "files.searchText", title: "Buscar un texto en archivos",
            summary: "Líneas que contienen un texto literal, con archivo y número de línea.",
            category: .files,
            parameters: [
                CatalogueParameter(id: "pattern", label: "Texto", kind: .textPattern, example: "TODO"),
                folder,
            ],
            variants: run(words("grep", "-rnF", "-e") + [value("pattern"), value("path")])
        ),
        CatalogueTask(
            id: "files.lineCount", title: "Contar líneas",
            summary: "Número de líneas de un archivo.",
            category: .files, parameters: [file], variants: run(words("wc", "-l") + [value("path")])
        ),
        CatalogueTask(
            id: "files.head", title: "Primeras líneas",
            summary: "Las primeras líneas de un archivo.",
            category: .files, parameters: [file, count("Líneas", 1...500, example: "20")],
            variants: run(words("head", "-n") + [value("count"), value("path")])
        ),
        CatalogueTask(
            id: "files.tail", title: "Últimas líneas",
            summary: "Las últimas líneas de un archivo, por ejemplo de un registro.",
            category: .files, parameters: [file, count("Líneas", 1...500, example: "20")],
            variants: run(words("tail", "-n") + [value("count"), value("path")])
        ),
        CatalogueTask(
            id: "files.sizeBytes", title: "Tamaño exacto de un archivo",
            summary: "El tamaño de un archivo en bytes.",
            category: .files, parameters: [file], variants: run(words("stat", "-f", "%z") + [value("path")])
        ),
        CatalogueTask(
            id: "files.type", title: "Qué tipo de archivo es",
            summary: "El tipo de contenido de un archivo, sin fiarse de la extensión.",
            category: .files, parameters: [file], variants: run(words("file") + [value("path")])
        ),
        CatalogueTask(
            id: "files.dsStore", title: "Borrar archivos .DS_Store",
            summary: "Lista y después borra los .DS_Store que Finder deja en una carpeta y sus subcarpetas.",
            category: .files, parameters: [folder],
            variants: [
                CatalogueTaskVariant(
                    id: "preview", title: "Ver cuáles", role: .preview,
                    stages: [[word("find"), value("path")] + words("-type", "f", "-name", ".DS_Store", "-print")]
                ),
                CatalogueTaskVariant(
                    id: "delete", title: "Borrarlos", role: .destructive,
                    stages: [[word("find"), value("path")] + words("-type", "f", "-name", ".DS_Store", "-delete")],
                    expectedWarnings: [.rmRecursiveForce]
                ),
            ]
        ),
    ]

    // MARK: Git

    private static let git: [CatalogueTask] = [
        CatalogueTask(
            id: "git.status", title: "Estado del repositorio",
            summary: "Rama actual y archivos cambiados, en formato corto.",
            category: .git, variants: run(words("git", "status", "-sb"))
        ),
        CatalogueTask(
            id: "git.log", title: "Últimos commits",
            summary: "Los últimos commits, uno por línea.",
            category: .git, parameters: [count("Commits", 1...200, example: "10")],
            variants: run(words("git", "log", "--oneline", "-n") + [value("count")])
        ),
        CatalogueTask(
            id: "git.diffStat", title: "Resumen de cambios",
            summary: "Archivos con cambios sin preparar y cuántas líneas cambian.",
            category: .git, variants: run(words("git", "diff", "--stat"))
        ),
        CatalogueTask(
            id: "git.branches", title: "Ramas y seguimiento",
            summary: "Ramas locales, su último commit y la rama remota que siguen.",
            category: .git, variants: run(words("git", "branch", "-vv"))
        ),
    ]

    // MARK: Homebrew

    private static let homebrew: [CatalogueTask] = [
        CatalogueTask(
            id: "brew.installed", title: "Paquetes instalados",
            summary: "Fórmulas y casks instalados con su versión.",
            category: .homebrew, variants: run(words("brew", "list", "--versions"))
        ),
        CatalogueTask(
            id: "brew.outdated", title: "Paquetes desactualizados",
            summary: "Paquetes con una versión más nueva disponible; Homebrew puede actualizarse antes.",
            category: .homebrew, variants: run(words("brew", "outdated"))
        ),
        CatalogueTask(
            id: "brew.cleanup", title: "Limpiar Homebrew",
            summary: "Muestra y después borra versiones antiguas y descargas en caché.",
            category: .homebrew,
            variants: [
                CatalogueTaskVariant(
                    id: "preview", title: "Ver qué borraría", role: .preview, stages: [words("brew", "cleanup", "-n")]
                ),
                CatalogueTaskVariant(
                    id: "cleanup", title: "Limpiar", role: .destructive, stages: [words("brew", "cleanup")]
                ),
            ]
        ),
    ]

    // MARK: Archives

    private static let archives: [CatalogueTask] = [
        CatalogueTask(
            id: "archives.tar", title: "Contenido de un .tar",
            summary: "Lista los archivos de un .tar, .tar.gz o .tgz sin extraerlos.",
            category: .archives, parameters: [archive], variants: run(words("tar", "-tf") + [value("path")])
        ),
        CatalogueTask(
            id: "archives.zip", title: "Contenido de un .zip",
            summary: "Lista los archivos de un .zip con su tamaño, sin extraerlos.",
            category: .archives,
            parameters: [CatalogueParameter(id: "path", label: "Archivo comprimido", kind: .path, example: "fotos.zip")],
            variants: run(words("unzip", "-l") + [value("path")])
        ),
    ]
}
