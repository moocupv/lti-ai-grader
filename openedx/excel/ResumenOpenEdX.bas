Attribute VB_Name = "ResumenOpenEdX"
'==============================================================================
' RESUMEN POR ALUMNO A PARTIR DEL INFORME DE OPEN EDX
'
' Lee el CSV "student state" que descarga el profesor desde el panel de
' instructor de Open edX para un problema "Custom JavaScript" que guarda cada
' correccion de la IA, y genera la hoja "Resumen por alumno" con una fila por
' alumno:
'   Identificacion | Enunciado | N. de envios | Ultima nota |
'   Ultima respuesta | Ultima correccion de la IA
' "Ultimo" = el envio con la fecha mas reciente. Los problemas de lectura se
' listan en la hoja "Incidencias".
'
' Uso: Alt+F8 -> ImportarInformeOpenEdX (o el boton de la hoja Inicio).
' Requiere Excel para Windows. Todo se procesa en local; el informe no sale del
' equipo.
'==============================================================================
Option Explicit

'==============================================================================
' NUCLEO: lectura del CSV de Open edX y decodificacion del JSON.
' No usa objetos de Excel ni COM: solo cadenas, matrices y Collection.
' Los almacenes de trabajo (m_...) son variables de modulo a proposito: las
' matrices no se pasan como parametros, asi el codigo se comporta igual en
' VBA y en el interprete Basic de LibreOffice con el que se ha probado.
' Por la misma razon, cada ReDim vive en un procedimiento propio (...Iniciar /
' ...Crecer) que no escribe elementos: LibreOffice pierde datos si un mismo
' procedimiento hace ReDim de una matriz y ademas escribe en ella.
'==============================================================================

Private Const MAX_CELDA As Long = 32000      ' Excel admite 32767 caracteres por celda
Private Const HOJA_RESUMEN As String = "Resumen por alumno"
Private Const HOJA_INCIDENCIAS As String = "Incidencias"

Private Type TIntento
    Fecha As String
    Enunciado As String
    Respuesta As String
    Correccion As String
    Nota As String
End Type

Private Type TResumen
    Usuario As String
    Enunciado As String
    Envios As Long
    Nota As String
    Respuesta As String
    Correccion As String
    Fecha As String
End Type

' --- analizador JSON ---
Private m_t As String                ' texto JSON que se esta analizando
Private m_p As Long                  ' posicion actual (base 1)
Private m_n As Long                  ' longitud del texto
Private m_it As TIntento             ' envio que se esta leyendo
Private m_r As TResumen              ' resumen del alumno que se esta procesando
Private m_int() As TIntento          ' envios del alumno actual
Private m_nInt As Long

' --- lector CSV ---
Private m_campos() As String         ' campos del registro actual

' --- resultados ---
Private m_res() As TResumen          ' un resumen por alumno
Private m_nRes As Long
Private m_incid() As String          ' incidencias: "fila|usuario|motivo"
Private m_nInc As Long
Private m_motivo As String           ' motivo de la incidencia del registro actual
Private m_donde As String            ' ultimo paso en curso (para los mensajes de error)
Private m_detalle As String          ' columnas encontradas (para los mensajes de error)

' --- constructor de cadenas (se usa de uno en uno, nunca anidado) ---
Private m_pb() As String
Private m_pn As Long

Private Sub PbIniciar()
    ReDim m_pb(0 To 63)
    m_pn = 0
End Sub

Private Sub PbCrecer()
    ReDim Preserve m_pb(0 To UBound(m_pb) * 2 + 1)
End Sub

Private Sub PbAgregar(ByVal texto As String)
    If m_pn > UBound(m_pb) Then PbCrecer
    m_pb(m_pn) = texto
    m_pn = m_pn + 1
End Sub

Private Sub CamposIniciar()
    ReDim m_campos(0 To 31)
End Sub

Private Sub CamposCrecer()
    ReDim Preserve m_campos(0 To UBound(m_campos) * 2 + 1)
End Sub

Private Sub IntIniciar()
    ReDim m_int(0 To 15)
    m_nInt = 0
End Sub

Private Sub IntCrecer()
    ReDim Preserve m_int(0 To UBound(m_int) * 2 + 1)
End Sub

Private Sub ResIniciar()
    ReDim m_res(0 To 63)
    m_nRes = 0
End Sub

Private Sub ResCrecer()
    ReDim Preserve m_res(0 To UBound(m_res) * 2 + 1)
End Sub

' Copia campo a campo (equivale a  m_res(idx) = m_r  y a  m_int(idx) = m_it)
Private Sub GuardarResumen(ByVal idx As Long)
    m_res(idx).Usuario = m_r.Usuario
    m_res(idx).Enunciado = m_r.Enunciado
    m_res(idx).Envios = m_r.Envios
    m_res(idx).Nota = m_r.Nota
    m_res(idx).Respuesta = m_r.Respuesta
    m_res(idx).Correccion = m_r.Correccion
    m_res(idx).Fecha = m_r.Fecha
End Sub

Private Sub GuardarIntento(ByVal idx As Long)
    m_int(idx).Fecha = m_it.Fecha
    m_int(idx).Enunciado = m_it.Enunciado
    m_int(idx).Respuesta = m_it.Respuesta
    m_int(idx).Correccion = m_it.Correccion
    m_int(idx).Nota = m_it.Nota
End Sub

Private Sub IncIniciar()
    ReDim m_incid(0 To 15)
    m_nInc = 0
End Sub

Private Sub IncCrecer()
    ReDim Preserve m_incid(0 To UBound(m_incid) * 2 + 1)
End Sub

Private Function PbUnir() As String
    If m_pn = 0 Then
        PbUnir = ""
    Else
        PbUnir = Join(m_pb, "")             ' los huecos sin usar son cadenas vacias
    End If
End Function

'------------------------------------------------------------------------------
' CSV (RFC 4180): campos entre comillas, comillas dobles escapadas, saltos de
' linea dentro de los campos. Los campos que no interesan no se construyen
' (el campo "state" del informe mide cientos de miles de caracteres).
' Rellena m_campos y devuelve el numero de campos, o 0 si no queda texto.
'------------------------------------------------------------------------------
Private Function LeerRegistroCsv(ByRef t As String, ByRef pos As Long, _
        ByVal c1 As Long, ByVal c2 As Long, ByVal todos As Boolean) As Long
    Dim lon As Long, n As Long, quiere As Boolean
    Dim q As Long, a As Long, ch As String, valor As String

    lon = Len(t)
    If pos > lon Then
        LeerRegistroCsv = 0
        Exit Function
    End If
    n = 0
    Do
        quiere = False
        If todos Then quiere = True
        If n = c1 Or n = c2 Then quiere = True
        valor = ""
        If Mid$(t, pos, 1) = """" Then
            pos = pos + 1
            If quiere Then PbIniciar
            Do
                q = InStr(pos, t, """")
                If q = 0 Then Err.Raise 1100, , "Campo entrecomillado sin cerrar en el CSV"
                If quiere And q > pos Then PbAgregar Mid$(t, pos, q - pos)
                If Mid$(t, q + 1, 1) = """" Then
                    If quiere Then PbAgregar """"
                    pos = q + 2
                Else
                    pos = q + 1
                    Exit Do
                End If
            Loop
            If quiere Then valor = PbUnir()
        Else
            a = pos
            Do While a <= lon
                ch = Mid$(t, a, 1)
                If ch = "," Or ch = vbCr Or ch = vbLf Then Exit Do
                a = a + 1
            Loop
            If quiere Then valor = Mid$(t, pos, a - pos)
            pos = a
        End If

        If n > UBound(m_campos) Then CamposCrecer
        m_campos(n) = valor
        n = n + 1

        If pos > lon Then Exit Do
        ch = Mid$(t, pos, 1)
        If ch = "," Then
            pos = pos + 1
        ElseIf ch = vbCr Then
            pos = pos + 1
            If Mid$(t, pos, 1) = vbLf Then pos = pos + 1
            Exit Do
        ElseIf ch = vbLf Then
            pos = pos + 1
            Exit Do
        Else
            Err.Raise 1101, , "CSV mal formado: se esperaba una coma o un fin de línea"
        End If
    Loop
    LeerRegistroCsv = n
End Function

' Posicion (base 0) de la primera columna cuyo nombre coincide con alguno de los candidatos; -1 si no hay
Private Function BuscarColumna(ByVal n As Long, ByVal candidatos As String) As Long
    Dim i As Long, nombre As String
    For i = 0 To n - 1
        nombre = LCase$(Trim$(m_campos(i)))
        If Len(nombre) > 0 Then
            If InStr(1, "|" & candidatos & "|", "|" & nombre & "|") > 0 Then
                BuscarColumna = i
                Exit Function
            End If
        End If
    Next i
    BuscarColumna = -1
End Function

'------------------------------------------------------------------------------
' JSON: solo se extrae lo necesario. No se construye ningun arbol.
'------------------------------------------------------------------------------
Private Sub JsSaltarEspacios()
    Dim c As Long
    Do While m_p <= m_n
        c = AscW(Mid$(m_t, m_p, 1))
        If c = 32 Or c = 9 Or c = 10 Or c = 13 Then
            m_p = m_p + 1
        Else
            Exit Do
        End If
    Loop
End Sub

' Busca la comilla que cierra la cadena que empieza en m_p (que apunta a la comilla de apertura)
Private Function JsBuscarCierre() As Long
    Dim ini As Long, q As Long, k As Long, barras As Long
    ini = m_p + 1
    q = ini
    Do
        q = InStr(q, m_t, """")
        If q = 0 Then Err.Raise 1001, , "Cadena JSON sin cerrar"
        barras = 0
        k = q - 1
        Do While k >= ini
            If Mid$(m_t, k, 1) <> "\" Then Exit Do
            barras = barras + 1
            k = k - 1
        Loop
        If barras Mod 2 = 0 Then Exit Do
        q = q + 1
    Loop
    JsBuscarCierre = q
End Function

' Valor de una cadena hexadecimal de 1 a 4 digitos, calculado a mano (no depende de CLng/Val sobre cadenas)
Private Function HexNum(ByVal h As String) As Long
    Dim i As Long, v As Long, d As Long, c As Long
    If Len(h) = 0 Then Err.Raise 1008, , "Secuencia \u vacia en el JSON"
    For i = 1 To Len(h)
        c = AscW(Mid$(h, i, 1))
        If c >= 48 And c <= 57 Then
            d = c - 48
        ElseIf c >= 65 And c <= 70 Then
            d = c - 55
        ElseIf c >= 97 And c <= 102 Then
            d = c - 87
        Else
            Err.Raise 1008, , "Secuencia \u no valida en el JSON: " & h
        End If
        v = v * 16 + d
    Next i
    HexNum = v
End Function

Private Function JsDesescapar(ByVal s As String) As String
    Dim p As Long, q As Long, c As String, h As String
    If InStr(1, s, "\") = 0 Then
        JsDesescapar = s
        Exit Function
    End If
    PbIniciar
    p = 1
    Do
        q = InStr(p, s, "\")
        If q = 0 Then
            PbAgregar Mid$(s, p)
            Exit Do
        End If
        If q > p Then PbAgregar Mid$(s, p, q - p)
        c = Mid$(s, q + 1, 1)
        Select Case c
            Case """", "\", "/"
                PbAgregar c
            Case "b"
                PbAgregar Chr$(8)
            Case "f"
                PbAgregar Chr$(12)
            Case "n"
                PbAgregar vbLf
            Case "r"
                PbAgregar vbCr
            Case "t"
                PbAgregar vbTab
            Case "u"
                h = Mid$(s, q + 2, 4)
                m_donde = "JsDesescapar, secuencia \u" & h
                PbAgregar ChrW(HexNum(h))
                q = q + 4
            Case Else
                PbAgregar c
        End Select
        p = q + 2
    Loop
    JsDesescapar = PbUnir()
End Function

Private Function JsLeerCadena() As String
    Dim ini As Long, q As Long
    m_donde = "JsLeerCadena"
    ini = m_p + 1
    q = JsBuscarCierre()
    JsLeerCadena = JsDesescapar(Mid$(m_t, ini, q - ini))
    m_p = q + 1
End Function

' Avanza m_p por encima del valor JSON que empieza en m_p, sin interpretarlo
Private Sub JsSaltarValor()
    Dim c As String, prof As Long, q As Long
    JsSaltarEspacios
    c = Mid$(m_t, m_p, 1)
    If c = """" Then
        q = JsBuscarCierre()
        m_p = q + 1
    ElseIf c = "{" Or c = "[" Then
        prof = 0
        Do While m_p <= m_n
            c = Mid$(m_t, m_p, 1)
            If c = """" Then
                q = JsBuscarCierre()
                m_p = q + 1
            Else
                If c = "{" Or c = "[" Then prof = prof + 1
                If c = "}" Or c = "]" Then prof = prof - 1
                m_p = m_p + 1
                If prof = 0 Then Exit Do
            End If
        Loop
    Else
        Do While m_p <= m_n
            c = Mid$(m_t, m_p, 1)
            If c = "," Or c = "}" Or c = "]" Or c = " " Or c = vbCr Or c = vbLf Or c = vbTab Then Exit Do
            m_p = m_p + 1
        Loop
    End If
End Sub

' Si el valor es una cadena la devuelve; si no, lo salta y devuelve ""
Private Function JsValorCadena() As String
    JsSaltarEspacios
    If Mid$(m_t, m_p, 1) = """" Then
        JsValorCadena = JsLeerCadena()
    Else
        JsSaltarValor
        JsValorCadena = ""
    End If
End Function

Private Sub JsIniciarObjeto(ByVal json As String)
    m_t = json
    m_n = Len(json)
    m_p = 1
    JsSaltarEspacios
    If Mid$(m_t, m_p, 1) <> "{" Then Err.Raise 1002, , "El contenido no es un objeto JSON"
    m_p = m_p + 1
End Sub

' Siguiente clave del objeto actual; devuelve False cuando el objeto termina
Private Function JsSiguienteClave(ByRef clave As String) As Boolean
    Dim c As String
    Do
        JsSaltarEspacios
        If m_p > m_n Then Err.Raise 1003, , "JSON incompleto"
        c = Mid$(m_t, m_p, 1)
        If c = "}" Then
            m_p = m_p + 1
            JsSiguienteClave = False
            Exit Function
        End If
        If c = "," Then
            m_p = m_p + 1
        Else
            If c <> """" Then Err.Raise 1004, , "JSON mal formado: se esperaba una clave"
            clave = JsLeerCadena()
            JsSaltarEspacios
            If Mid$(m_t, m_p, 1) <> ":" Then Err.Raise 1005, , "JSON mal formado: falta ':'"
            m_p = m_p + 1
            JsSaltarEspacios
            JsSiguienteClave = True
            Exit Function
        End If
    Loop
End Function

' Valor de la clave de primer nivel indicada, si es una cadena (p. ej. "answer")
Private Function JsonObtenerCadena(ByVal json As String, ByVal clave As String, ByRef encontrado As Boolean) As String
    Dim k As String
    m_donde = "JsonObtenerCadena"
    encontrado = False
    JsIniciarObjeto json
    Do While JsSiguienteClave(k)
        If k = clave And Mid$(m_t, m_p, 1) = """" Then
            JsonObtenerCadena = JsLeerCadena()
            encontrado = True
            Exit Function
        End If
        JsSaltarValor
    Loop
End Function

' Lee el envio que empieza en m_p (la llave de apertura) y lo deja en m_it
Private Sub JsLeerIntento()
    Dim k As String
    m_donde = "JsLeerIntento"
    m_it.Fecha = ""
    m_it.Enunciado = ""
    m_it.Respuesta = ""
    m_it.Correccion = ""
    m_it.Nota = ""
    m_p = m_p + 1
    Do While JsSiguienteClave(k)
        Select Case k
            Case "fecha":      m_it.Fecha = JsValorCadena()
            Case "enunciado":  m_it.Enunciado = JsValorCadena()
            Case "respuesta":  m_it.Respuesta = JsValorCadena()
            Case "correccion": m_it.Correccion = JsValorCadena()
            Case "nota":       m_it.Nota = JsValorCadena()
            Case Else:         JsSaltarValor
        End Select
    Loop
End Sub

' Lee la lista "intentos" del JSON interno en m_int. Devuelve el numero de envios, o -1 si no existe la clave.
Private Function JsonLeerIntentos(ByVal json As String) As Long
    Dim k As String, c As String
    m_donde = "JsonLeerIntentos"
    JsonLeerIntentos = -1
    m_nInt = 0
    JsIniciarObjeto json
    Do While JsSiguienteClave(k)
        If k = "intentos" And Mid$(m_t, m_p, 1) = "[" Then
            IntIniciar
            m_p = m_p + 1
            Do
                JsSaltarEspacios
                If m_p > m_n Then Err.Raise 1006, , "JSON incompleto dentro de 'intentos'"
                c = Mid$(m_t, m_p, 1)
                If c = "]" Then
                    m_p = m_p + 1
                    Exit Do
                ElseIf c = "," Then
                    m_p = m_p + 1
                ElseIf c = "{" Then
                    JsLeerIntento
                    If m_nInt > UBound(m_int) Then IntCrecer
                    GuardarIntento m_nInt
                    m_nInt = m_nInt + 1
                Else
                    Err.Raise 1007, , "JSON mal formado dentro de 'intentos'"
                End If
            Loop
            JsonLeerIntentos = m_nInt
            Exit Function
        End If
        JsSaltarValor
    Loop
End Function

'------------------------------------------------------------------------------
' Preparacion del texto para una celda de Excel
'------------------------------------------------------------------------------
Private Function TextoParaCelda(ByVal s As String) As String
    Dim i As Long, c As Long, ini As Long, sucio As Boolean

    s = Replace(s, vbCrLf, vbLf)
    s = Replace(s, vbCr, vbLf)
    ' quita saltos de linea y espacios al principio y al final
    Do While Len(s) > 0
        If Left$(s, 1) = vbLf Or Left$(s, 1) = " " Or Left$(s, 1) = vbTab Then
            s = Mid$(s, 2)
        Else
            Exit Do
        End If
    Loop
    Do While Len(s) > 0
        If Right$(s, 1) = vbLf Or Right$(s, 1) = " " Or Right$(s, 1) = vbTab Then
            s = Left$(s, Len(s) - 1)
        Else
            Exit Do
        End If
    Loop

    ' caracteres de control no admitidos en una celda (se admiten tabulador y salto de linea)
    For i = 1 To Len(s)
        c = AscW(Mid$(s, i, 1))
        If c >= 0 And c < 32 And c <> 9 And c <> 10 Then
            sucio = True
            Exit For
        End If
    Next i
    If sucio Then
        PbIniciar
        ini = 1
        For i = 1 To Len(s)
            c = AscW(Mid$(s, i, 1))
            If c >= 0 And c < 32 And c <> 9 And c <> 10 Then
                If i > ini Then PbAgregar Mid$(s, ini, i - ini)
                PbAgregar " "
                ini = i + 1
            End If
        Next i
        If ini <= Len(s) Then PbAgregar Mid$(s, ini)
        s = PbUnir()
    End If

    ' un texto que empieza por = + - @ podria interpretarse como formula
    If Len(s) > 0 Then
        Select Case Left$(s, 1)
            Case "=", "+", "-", "@"
                s = " " & s
        End Select
    End If

    If Len(s) > MAX_CELDA Then
        s = Left$(s, MAX_CELDA) & vbLf & "[... texto truncado: supera el límite de una celda de Excel]"
    End If
    TextoParaCelda = s
End Function

'------------------------------------------------------------------------------
' Procesa un registro del CSV y devuelve el resumen del alumno (en r).
' Devuelve False si no se pudo interpretar. m_motivo describe cualquier incidencia.
'------------------------------------------------------------------------------
Private Function ProcesarRegistro(ByVal usuario As String, ByVal json As String) As Boolean
    Dim interno As String, enc As Boolean, n As Long, i As Long, mejor As Long

    On Error GoTo Falla
    m_r.Usuario = usuario
    m_r.Enunciado = ""
    m_r.Envios = 0
    m_r.Nota = ""
    m_r.Respuesta = ""
    m_r.Correccion = ""
    m_r.Fecha = ""
    m_motivo = ""

    If Len(Trim$(json)) = 0 Then
        m_motivo = "El alumno no tiene respuestas guardadas"
        ProcesarRegistro = True
        Exit Function
    End If

    m_donde = "ProcesarRegistro: leer 'answer'"
    interno = JsonObtenerCadena(json, "answer", enc)
    If Not enc Then interno = json
    m_donde = "ProcesarRegistro: leer los envios"
    n = JsonLeerIntentos(interno)
    m_donde = "ProcesarRegistro: elegir el ultimo envio"
    If n < 0 Then
        m_motivo = "No se encontró la lista de envíos (""intentos"") en la respuesta del alumno"
        ProcesarRegistro = True
        Exit Function
    End If
    m_r.Envios = n
    If n = 0 Then
        m_motivo = "El alumno no tiene ningún envío registrado"
        ProcesarRegistro = True
        Exit Function
    End If

    mejor = n - 1                                ' por defecto, el ultimo de la lista
    For i = 0 To n - 1
        If Len(m_int(i).Fecha) > 0 Then
            If Len(m_int(mejor).Fecha) = 0 Then
                mejor = i
            ElseIf StrComp(m_int(i).Fecha, m_int(mejor).Fecha, vbBinaryCompare) >= 0 Then
                mejor = i
            End If
        End If
    Next i
    m_r.Fecha = m_int(mejor).Fecha
    m_r.Enunciado = m_int(mejor).Enunciado
    m_r.Nota = m_int(mejor).Nota
    m_r.Respuesta = m_int(mejor).Respuesta
    m_r.Correccion = m_int(mejor).Correccion
    ProcesarRegistro = True
    Exit Function

Falla:
    m_motivo = "No se pudo interpretar la respuesta: " & Err.Description & " (error " & Err.Number & ") [" & m_donde & ", posicion " & m_p & "]"
    ProcesarRegistro = False
End Function

'------------------------------------------------------------------------------
' Recorre todo el CSV y deja los resultados en m_res / m_incid. Un resumen por
' alumno (si un alumno aparece dos veces se conserva el registro con el envio
' mas reciente). Devuelve el numero de alumnos.
'------------------------------------------------------------------------------
Private Function ExtraerResumenes(ByRef t As String) As Long
    Dim pos As Long, nCampos As Long, cUsr As Long, cJson As Long, fila As Long, i As Long
    Dim ok As Boolean
    Dim claves As New Collection, idx As Long, clave As String, usuario As String, json As String

    If Left$(t, 1) = ChrW(&HFEFF) Then t = Mid$(t, 2)          ' marca BOM de UTF-8
    CamposIniciar
    ResIniciar
    IncIniciar
    m_detalle = ""
    pos = 1

    nCampos = LeerRegistroCsv(t, pos, -1, -1, True)
    If nCampos = 0 Then Err.Raise 1200, , "El fichero está vacío"
    cUsr = BuscarColumna(nCampos, "username|user name|usuario|nombre de usuario|student|alumno|user")
    cJson = BuscarColumna(nCampos, "respuesta|answer|response")
    If cUsr < 0 Or cJson < 0 Then
        For i = 0 To nCampos - 1
            If i > 0 Then m_detalle = m_detalle & ", "
            m_detalle = m_detalle & m_campos(i)
        Next i
        Err.Raise 1201, , "No se reconocen las columnas del informe. Faltan 'username' y/o 'Respuesta' (o 'Answer')."
    End If
    fila = 1

    Do
        nCampos = LeerRegistroCsv(t, pos, cUsr, cJson, False)
        If nCampos = 0 Then Exit Do
        fila = fila + 1
        If fila Mod 5 = 0 Then Progreso fila
        If nCampos > 1 Or Len(m_campos(0)) > 0 Then
            usuario = Trim$(m_campos(cUsr))
            json = m_campos(cJson)
            ok = ProcesarRegistro(usuario, json)
            If Len(m_motivo) > 0 Then
                If m_nInc > UBound(m_incid) Then IncCrecer
                m_incid(m_nInc) = fila & "|" & usuario & "|" & m_motivo
                m_nInc = m_nInc + 1
            End If
            If ok Or Len(usuario) > 0 Then
                clave = "u:" & LCase$(usuario)
                idx = -1
                On Error Resume Next
                idx = claves(clave)
                On Error GoTo 0
                If idx >= 0 Then
                    If StrComp(m_r.Fecha, m_res(idx).Fecha, vbBinaryCompare) > 0 Then GuardarResumen idx
                Else
                    If m_nRes > UBound(m_res) Then ResCrecer
                    GuardarResumen m_nRes
                    claves.Add m_nRes, clave
                    m_nRes = m_nRes + 1
                End If
            End If
        End If
    Loop
    ExtraerResumenes = m_nRes
End Function

'==============================================================================
' CAPA DE EXCEL (solo Windows): selector de fichero, lectura UTF-8 con ADODB y
' escritura de las hojas de resultados.
'==============================================================================

' Macro principal: pide el CSV de Open edX y genera la hoja "Resumen por alumno"
Public Sub ImportarInformeOpenEdX()
    Dim ruta As Variant
#If Mac Then
    MsgBox "Esta macro necesita Excel para Windows (lee el CSV en UTF-8 con ADODB).", vbExclamation
    Exit Sub
#End If
    ruta = Application.GetOpenFilename("Informe de Open edX (*.csv),*.csv", , _
        "Selecciona el informe CSV descargado de Open edX")
    If VarType(ruta) = vbBoolean Then Exit Sub              ' se cancelo el dialogo
    ProcesarInforme CStr(ruta)
End Sub

Private Sub Progreso(ByVal fila As Long)
    Application.StatusBar = "Analizando el informe... registro " & fila
    DoEvents
End Sub

Private Sub RestaurarExcel()
    Application.StatusBar = False
    Application.ScreenUpdating = True
    Application.EnableEvents = True
    Application.DisplayAlerts = True
End Sub

Private Sub ProcesarInforme(ByVal ruta As String)
    Dim texto As String, n As Long, inicio As Double, aviso As String

    On Error GoTo Falla
    inicio = Timer
    Application.ScreenUpdating = False
    Application.EnableEvents = False
    Application.StatusBar = "Leyendo el informe..."
    texto = LeerTextoUtf8(ruta)

    Application.StatusBar = "Analizando el informe..."
    n = ExtraerResumenes(texto)
    texto = ""                                                ' libera la memoria del informe

    Application.StatusBar = "Escribiendo las hojas..."
    EscribirResumen n
    EscribirIncidencias

    RestaurarExcel
    aviso = "Alumnos procesados: " & n & vbCrLf & "Tiempo: " & Format(Timer - inicio, "0.0") & " s"
    If m_nInc > 0 Then
        aviso = aviso & vbCrLf & vbCrLf & "Incidencias: " & m_nInc & " (consulta la hoja """ & HOJA_INCIDENCIAS & """)."
    End If
    ThisWorkbook.Worksheets(HOJA_RESUMEN).Activate
    MsgBox aviso, vbInformation, "Informe de Open edX"
    Exit Sub

Falla:
    aviso = Err.Description
    If Err.Number <> 0 Then aviso = aviso & " (código " & Err.Number & ")"
    If Len(m_detalle) > 0 Then aviso = aviso & vbCrLf & vbCrLf & "Columnas encontradas: " & m_detalle
    RestaurarExcel
    MsgBox "No se pudo procesar el informe:" & vbCrLf & vbCrLf & aviso, vbExclamation, "Informe de Open edX"
End Sub

' Lee un fichero de texto en UTF-8 (el informe de Open edX puede superar los 100 MB)
Private Function LeerTextoUtf8(ByVal ruta As String) As String
    Dim st As Object
    Set st = CreateObject("ADODB.Stream")
    st.Type = 2                                               ' adTypeText
    st.Charset = "utf-8"
    st.Open
    st.LoadFromFile ruta
    LeerTextoUtf8 = st.ReadText(-1)                           ' adReadAll
    st.Close
End Function

' Crea una hoja con ese nombre al final del libro (si ya existia, se sustituye)
Private Function NuevaHoja(ByVal nombre As String) As Worksheet
    Dim ws As Worksheet
    Application.DisplayAlerts = False
    On Error Resume Next
    ThisWorkbook.Worksheets(nombre).Delete
    On Error GoTo 0
    Application.DisplayAlerts = True
    Set ws = ThisWorkbook.Worksheets.Add(After:=ThisWorkbook.Worksheets(ThisWorkbook.Worksheets.Count))
    ws.Name = nombre
    Set NuevaHoja = ws
End Function

Private Sub EstiloCabecera(ByVal rango As Range)
    With rango
        .Font.Bold = True
        .Font.Color = RGB(255, 255, 255)
        .Interior.Color = RGB(31, 78, 121)
        .VerticalAlignment = xlCenter
        .WrapText = True
    End With
End Sub

Private Sub EscribirResumen(ByVal n As Long)
    Dim ws As Worksheet, datos() As Variant, i As Long, ultima As Long

    Set ws = NuevaHoja(HOJA_RESUMEN)
    ws.Cells.Font.Name = "Arial"
    ws.Cells.Font.Size = 10
    ws.Cells.NumberFormat = "@"                               ' todo como texto: "12/15" no debe convertirse en fecha
    ws.Range("C:C").NumberFormat = "0"                        ' salvo el numero de envios

    ws.Range("A1").Value = "Identificaci" & ChrW(243) & "n"
    ws.Range("B1").Value = "Enunciado"
    ws.Range("C1").Value = "N" & ChrW(186) & " de env" & ChrW(237) & "os"
    ws.Range("D1").Value = ChrW(218) & "ltima nota"
    ws.Range("E1").Value = ChrW(218) & "ltima respuesta"
    ws.Range("F1").Value = ChrW(218) & "ltima correcci" & ChrW(243) & "n de la IA"
    EstiloCabecera ws.Range("A1:F1")
    ws.Rows(1).RowHeight = 30

    If n > 0 Then
        ReDim datos(1 To n, 1 To 6)
        For i = 1 To n
            datos(i, 1) = TextoParaCelda(m_res(i - 1).Usuario)
            datos(i, 2) = TextoParaCelda(m_res(i - 1).Enunciado)
            datos(i, 3) = m_res(i - 1).Envios
            datos(i, 4) = TextoParaCelda(m_res(i - 1).Nota)
            datos(i, 5) = TextoParaCelda(m_res(i - 1).Respuesta)
            datos(i, 6) = TextoParaCelda(m_res(i - 1).Correccion)
        Next i
        ws.Range("A2").Resize(n, 6).Value = datos
    End If
    ultima = n + 1

    ws.Columns("A").ColumnWidth = 22
    ws.Columns("B").ColumnWidth = 55
    ws.Columns("C").ColumnWidth = 11
    ws.Columns("D").ColumnWidth = 12
    ws.Columns("E").ColumnWidth = 55
    ws.Columns("F").ColumnWidth = 90
    If n > 0 Then
        With ws.Range("A2:F" & ultima)
            .VerticalAlignment = xlTop
            .WrapText = True
        End With
        ws.Range("C2:D" & ultima).HorizontalAlignment = xlCenter
        ws.Rows("2:" & ultima).RowHeight = 90                 ' filas compactas; el texto completo esta en la celda
    End If

    ws.Range("A1:F" & ultima).AutoFilter
    ws.Activate
    ActiveWindow.FreezePanes = False
    ws.Range("B2").Select
    ActiveWindow.FreezePanes = True
    ws.Range("A1").Select
End Sub

Private Sub EscribirIncidencias()
    Dim ws As Worksheet, i As Long, partes() As String

    If m_nInc = 0 Then
        Application.DisplayAlerts = False
        On Error Resume Next
        ThisWorkbook.Worksheets(HOJA_INCIDENCIAS).Delete
        On Error GoTo 0
        Application.DisplayAlerts = True
        Exit Sub
    End If

    Set ws = NuevaHoja(HOJA_INCIDENCIAS)
    ws.Cells.Font.Name = "Arial"
    ws.Cells.Font.Size = 10
    ws.Cells.NumberFormat = "@"
    ws.Range("A1").Value = "Fila del CSV"
    ws.Range("B1").Value = "Identificaci" & ChrW(243) & "n"
    ws.Range("C1").Value = "Motivo"
    EstiloCabecera ws.Range("A1:C1")
    For i = 0 To m_nInc - 1
        partes = Split(m_incid(i), "|", 3)
        ws.Cells(i + 2, 1).Value = partes(0)
        ws.Cells(i + 2, 2).Value = TextoParaCelda(partes(1))
        ws.Cells(i + 2, 3).Value = partes(2)
    Next i
    ws.Columns("A").ColumnWidth = 14
    ws.Columns("B").ColumnWidth = 24
    ws.Columns("C").ColumnWidth = 110
    ws.Range("A1:C" & m_nInc + 1).AutoFilter
End Sub
