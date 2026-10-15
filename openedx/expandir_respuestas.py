#!/usr/bin/env python3
"""
Convierte el "Informe de respuestas a problemas" de Open edX (Panel de instructor >
Descarga de datos) en un CSV con UNA FILA POR INTENTO, listo para Excel/LibreOffice.

Uso:
    python3 expandir_respuestas.py informe.csv -o correcciones.csv
    python3 expandir_respuestas.py informe.csv --columna "Answer"

Detecta la columna de respuesta por nombre (Answer / Respuesta). Si tu informe usa otro
nombre, indícalo con --columna. Las demás columnas (usuario, ubicación...) se conservan.
"""
import argparse
import csv
import html
import json
import sys

NUEVAS = ["intento_num", "fecha", "nota", "enunciado", "respuesta", "correccion"]


def cargar_json(texto):
    """Devuelve el dict con la clave "intentos".

    Open edX guarda la respuesta de un jsinput como {"answer": "<json>", "state": "<json>"},
    con el JSON de getGrade dentro como cadena. Se desempaqueta hasta encontrar "intentos".
    """
    for candidato in (texto, html.unescape(texto)):
        try:
            valor = json.loads(candidato)
        except Exception:
            continue
        for _ in range(5):
            if isinstance(valor, dict) and "intentos" in valor:
                return valor
            if isinstance(valor, dict) and "answer" in valor:
                valor = valor["answer"]
            elif isinstance(valor, str):
                try:
                    valor = json.loads(valor)
                except Exception:
                    break
            else:
                break
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("entrada")
    ap.add_argument("-o", "--salida", default="correcciones_expandido.csv")
    ap.add_argument("--columna", default=None, help="Nombre de la columna con el JSON de intentos")
    args = ap.parse_args()

    csv.field_size_limit(sys.maxsize)

    with open(args.entrada, newline="", encoding="utf-8-sig") as f:
        lector = csv.DictReader(f)
        campos = lector.fieldnames or []
        col = args.columna or next(
            (c for c in campos if c.strip().lower() in ("answer", "respuesta")), None)
        if col is None or col not in campos:
            sys.exit(f"No encuentro la columna de respuesta. Columnas: {campos}. Usa --columna.")

        otras = [c for c in campos if c != col]
        filas_salida, ilegibles = [], 0

        for fila in lector:
            datos = cargar_json(fila.get(col, "") or "")
            intentos = datos.get("intentos") if isinstance(datos, dict) else None
            base = {c: fila.get(c, "") for c in otras}
            if datos is not None and not intentos:
                # JSON válido pero sin intentos (p. ej. se pulsó Enviar con el almacén vacío)
                filas_salida.append({**base, "respuesta": "(sin intentos)"})
                continue
            if not intentos:
                ilegibles += 1
                filas_salida.append({**base, "respuesta": fila.get(col, "")})
                continue
            for n, it in enumerate(intentos, 1):
                filas_salida.append({
                    **base,
                    "intento_num": n,
                    "fecha": it.get("fecha", ""),
                    "nota": it.get("nota", ""),
                    "enunciado": it.get("enunciado", ""),
                    "respuesta": it.get("respuesta", ""),
                    "correccion": it.get("correccion", ""),
                })

    # utf-8-sig para que Excel abra bien los acentos
    with open(args.salida, "w", newline="", encoding="utf-8-sig") as f:
        escritor = csv.DictWriter(f, fieldnames=otras + NUEVAS, extrasaction="ignore")
        escritor.writeheader()
        escritor.writerows(filas_salida)

    print(f"{len(filas_salida)} filas escritas en {args.salida}"
          + (f" ({ilegibles} filas sin JSON de intentos válido)" if ilegibles else ""))


if __name__ == "__main__":
    main()
