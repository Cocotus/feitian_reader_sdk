using System;
using System.Xml;
using System.IO;
using System.Collections.Generic;
using System.Data;
using System.Reflection;
using System.Globalization;
using Csx.Utilities.Utility;
using System.Linq;
using PCSC;
using System.Runtime.ConstrainedExecution;
using PCSC.Iso7816;

namespace CsxUtilitiesOcrCardReader
{
    /// <summary>
    /// EGK Karte mittels PC/SC-Technik auslesen
    /// </summary>
    /// <remarks>
    /// pm20161014 - Überarbeitung der gesamten Klasse
    /// Besseres Fehlerhandling, mehr Log! Gesamten Auslese-Ablauf nach Anleitung "gemLF_Impl_eGK_V160.pdf" (off. Dokument der GEMATIK) umgesetzt.
    /// Des Weiteren werden neue Infos aus EGKRoot ausgelesen, was vorher nie berücksichtigt wurde.
    /// QUELLEN: 
    /// - \\sid\team\Produkte\CEUS\CEUS-RD\1-Dokumentation\3-Schnittstellen\EGK\APDU_Schnittstellenbeschreibung.pdf
    /// - Implementierungsleitfaden zur Einbindung der eGK in die Primärsysteme der Leistungserbringer(), Version 1.6
    /// Auszug:
    /// Bei einem eGK-Datensatz sind insgesamt drei aufeinanderfolgende ReadBinary-
    /// Kommandos erforderlich, um alle Daten auszulesen. Es wird jeweils ein
    /// Kommando mit P1=0x8C, P1=0x81 sowie P1=0x82 gesendet, für Le soll jeweils
    /// das extended Length Le=00 00 00 verwendet werden.
    /// CLA INS P1 P2 Le       adressierter Container
    /// 00  B0  8C 00 00 00 00 VST Versichertenstatus
    /// 00  B0  81 00 00 00 00 PD Patientendaten
    /// 00  B0  82 00 00 00 00 VD Versicherungsdaten
    /// Die jeweils zurückgelieferten Daten enthalten die Rohdaten des adressierten
    /// Containers. Bei einem eGK-Datensatz enthält der Container Versichertenstatus (VST) die
    /// zusätzlichen Tags 0x91, 0x92 und 0x93 gemäß [gemSpec_mobKT]. Die Patientendaten (PD) sowie die Versicherungsdaten (VD) liegen in den
    /// jeweiligen Containern in einem gezippten XML-Format vor. Zur weiteren Verarbeitung siehe hier auch [gemSpec_eGK].
    /// Bei fehlerfreier Ausführung wird zusätzlich Code 0x9000 an den Datenstrom angehängt.
    /// 
    /// jl20160707 - Ersterstellung
    /// Es wird eine Open Source Klasse für .NET: https://github.com/danm-de/pcsc-sharp eingebunden
    /// Durch das Lesen mittelsPC/SC anstatt CTAPI-AusleseTechnik, kann auf config.xml Angaben wie Cardreader-Port komplett verzichtet werden! Es muss nun auch nicht immer mehr eine "CTDEUTIN.dll" vorhanden sein!
    /// Inspiriert durch freies Tool Chipcardmaster! http://www.chipcardmaster.de/
    /// </remarks>
    public class CardReader_PCSC
    {
        private List<LanguageCardXmlConfig> _config = new List<LanguageCardXmlConfig>();
        private int _configIndex = 0;
        //private Boolean _configFound = false;
        //private string root = @"C:\cks\CEUS Rettungsdienst\";
        //private string root = Directory.GetCurrentDirectory() + "\\";
        private string root = System.IO.Path.GetDirectoryName(System.Reflection.Assembly.GetEntryAssembly().Location) + "\\";

        public CardReader_PCSC()
        {

            // prüft ob wichtige Dateien vorhanden sind -> ansonsten aus Ressourcen kopieren und Anwendung zur Verfügung stellen
            if (!File.Exists(System.IO.Path.Combine(root, "languageOcr.xml")))
            {
                Utils.ExtractResourceToDisk("languageOcr.xml", System.IO.Path.Combine(root, "languageOcr.xml"));
            }
            if (!File.Exists(System.IO.Path.Combine(root, "blacklist.xml")))
            {
                Utils.ExtractResourceToDisk("blacklist.xml", System.IO.Path.Combine(root, "blacklist.xml"));
            }
            if (!File.Exists(System.IO.Path.Combine(root, "languageCard.xml")))
            {
                Logging.WriteInformation("CardReader_PCSC", "CardReader_PCSC", "Datei wird wiederhergestellt: " + System.IO.Path.Combine(root, "languageCard.xml"));
                Utils.ExtractResourceToDisk("languageCard.xml", System.IO.Path.Combine(root, "languageCard.xml"));
            }
            ReadCardXmlConfig();
            Logging.WriteInformation("CardReader_PCSC", "CardReader_PCSC", "Ende Konstruktor");
        }




        /// <summary>
        /// EGK Karte mittels PC/SC-Technik auslesen
        /// </summary>
        /// <returns>EGK-Karteninformation (Patientendaten/Versichertendaten)</returns>
        /// <remarks>
        /// pm20161014 - Aktualisiert. Besseres Fehlerhandling, mehr Log. Gesamten Auslese-Ablauf nach Anleitung gemLF_Impl_eGK_V160.pdf (off. Dokument der GEMATIK) umgesetzt.
        /// jl20160707 - Ersterstellung
        /// </remarks>
        public CardReader.CardData ReadEGKPCSC()
        {
            try
            {
                System.IO.MemoryStream pd_xml;
                System.IO.MemoryStream vd_xml;
                CardReader.CardData carddata = new CardReader.CardData();

                using (SCardContext context = new SCardContext())
                {

                    context.Establish(SCardScope.System);
                    var readerNames = context.GetReaders();
                    if (Tools.IstLeerObj(readerNames) || readerNames.Length < 1)
                    {
                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", "Kein Kartenleser gefunden!");
                        return null;
                    }

                    foreach (string readerName in readerNames)
                    {
                        //pm20161017 EGK Auslesen hier nach Empfehlung des Ablaufschemas der Gematik umgesetzt, ebenso mehr Log!
                        using (var reader = new SCardReader(context))
                        {
                            Logging.WriteTesting("CardReader_PCSC", "ReadEGKPCSC", "Baue Verbindung zu Kartenleser " + readerName + " auf...");
                            Logging.WriteTesting("CardReader_PCSC", "ReadEGKPCSC", "Verbindungsstatus Kartenleser: " + reader.IsConnected);
                            if (reader.IsConnected)
                            {
                                reader.Disconnect(SCardReaderDisposition.Reset);
                                Logging.WriteTesting("CardReader_PCSC", "ReadEGKPCSC", "Kartenleser trennen! Status: " + reader.IsConnected);
                            }
                            //Logging.WriteTesting("CardReader_PCSC", "ReadEGKPCSC", "Kartenleser mit Exclusive Status connecten...");
                            //var sc = reader.Connect(readerName, SCardShareMode.Exclusive, SCardProtocol.Any);
                            //if (sc == SCardError.Success)
                            //{
                            //    reader.Disconnect(SCardReaderDisposition.Reset);
                            //    Logging.WriteTesting("CardReader_PCSC", "ReadEGKPCSC", "Kartenleser trennen! Status: " + reader.IsConnected);
                            //}
                            //else
                            //{
                            //    Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", "Kein exklusiver Zugriff auf Kartenleser möglich?! Muss aber! Stoppe auslesen! Gruppenrichtlinien angepasst nach http://chris-evans-dev.blogspot.com/2011/03/smartcard-pcsc-scardconnect-sharing.html ?");
                            //    return null;
                            //}
                            //System.Threading.Thread.Sleep(50);
                            //Logging.WriteTesting("CardReader_PCSC", "ReadEGKPCSC", "Kartenleser mit Shared Status connecten...");
                            //sc = reader.Connect(readerName, SCardShareMode.Shared, SCardProtocol.Any);

                            Logging.WriteTesting("CardReader_PCSC", "ReadEGKPCSC", "Kartenleser mit Shared Status connecten...");
                            var sc = reader.Connect(readerName, SCardShareMode.Shared, SCardProtocol.Any);
                            if (sc == SCardError.Success)
                            {
                                //Erfolgreich verbunden
                                SCardProtocol tmpprotokoll = default(SCardProtocol);
                                SCardState tmpstatus = default(SCardState);
                                string[] tmpreaders = null;
                                byte[] atr = null;
                                SCardError rueckmeldung = default(SCardError);
                                rueckmeldung = reader.Status(out tmpreaders, out tmpstatus, out tmpprotokoll, out atr);
                                if (rueckmeldung == SCardError.Success)
                                {
                                    Logging.WriteTesting("CardReader_PCSC", "ReadEGKPCSC", string.Format("Kartenleser: {1} , Protokoll: {0}, Status: {2} ", tmpprotokoll.ToString(), reader.ReaderName, tmpstatus.ToString()));
                                    if (atr != null && atr.Length > 0)
                                    {
                                        if (CheckForAtr(BitConverter.ToString(atr)) == false)
                                        {
                                            Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", "Karten-ATR nicht in XML gefunden - bitte einpflegen!: " + BitConverter.ToString(atr));
                                        }

                                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", "Karten-ATR: " + BitConverter.ToString(atr));
                                        using (PCSC.Iso7816.IsoReader isoReader = new PCSC.Iso7816.IsoReader(context, readerName, reader.CurrentShareMode, reader.ActiveProtocol))
                                        {
                                            resetCardreader(isoReader);
                                            requestCard(isoReader);
                                            if (getRootSelect(isoReader) == true)
                                            {
                                                int maxpuffer = -1;
                                                maxpuffer = ReadEGKKartenpuffer(isoReader);
                                                if (maxpuffer > 0)
                                                {
                                                    string egkversion = string.Empty;
                                                    string egkschemaversion = string.Empty;
                                                    egkschemaversion = ReadEGKKartenSchemaversion(isoReader);
                                                    egkversion = ReadEGKKartenversion(isoReader);
                                                    Logging.WriteTesting("CardReader_PCSC", "ReadEGKPCSC", string.Format("Kartendaten ausgelesen! Generation:{0}, Schemaversion:{1}", egkversion, egkschemaversion));
                                                    if (selectHCA(isoReader) == true)
                                                    {
                                                        pd_xml = ReadEGKPatientendaten(isoReader, maxpuffer);
                                                        vd_xml = ReadEGKVersichertendaten(isoReader, maxpuffer);
                                                        if (pd_xml != null && vd_xml != null)
                                                        {
                                                            // dict = operateData(pd_xml, vd_xml);
                                                            carddata = operateData(pd_xml, vd_xml);
                                                        }
                                                        else
                                                        {
                                                            Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", string.Format("Fehler beim Auslesen der Patientendaten/Versichertendaten der EGK-Karte! Kartenleser{0} - EGK-Generation:{1} - EGK-Schemaversion:{2}", reader.ReaderName, egkversion, egkschemaversion));
                                                        }
                                                    }
                                                    else
                                                    {
                                                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", string.Format("Fehler beim Selektieren des HCA Containers der EGK-Karte! Kartenleser{0} - EGK-Generation:{1} - EGK-Schemaversion:{2}", reader.ReaderName, egkversion, egkschemaversion));
                                                    }
                                                }
                                                else
                                                {
                                                    Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", string.Format("Fehler beim Auslesen des zulässigen maximalen Kartenpuffers der EGK-Karte! Kartenleser{0} - Karten-ATR:{1}", reader.ReaderName, BitConverter.ToString(atr)));
                                                }
                                            }
                                            else
                                            {
                                                Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", string.Format("Fehler beim Selektieren der EGK-Karte! Kartenleser{0} - Karten-ATR:{1}", reader.ReaderName, BitConverter.ToString(atr)));
                                            }
                                            ejectCard(isoReader);
                                        }

                                    }
                                }
                                else
                                {
                                    Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", "Keine Karte vorhanden bzw. Leser von anderer Applikation verwendet! Fehler:      " + PCSC.Utils.SCardHelper.StringifyError(sc));
                                }
                                reader.Disconnect(SCardReaderDisposition.Reset);
                            }
                            else
                            {
                                Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", "Keine Karte vorhanden bzw. Leser von anderer Applikation verwendet! Fehler: " + PCSC.Utils.SCardHelper.StringifyError(sc));
                            }
                        }

                        if (carddata.Name != string.Empty)
                        {
                            Logging.WriteInformation("CardReader_PCSC", "ReadEGKPCSC", "Lesen erfolgreich");
                            return carddata;
                        }
                    }
                }

                if (carddata.Name == string.Empty)
                {
                    //Logging.WriteWarning("CardReader_PCSC", "ReadEGKPCSC", "Keine Karte vorhanden bzw. Leser von anderer Applikation verwendet!");
                    return null;
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPCSC", "Lesen erfolgreich");
                    return carddata;
                }

            }
            catch (CardException cex)
            {
                Logging.WriteTracing("CardReader_PCSC", "ReadEGKPCSC", "Verbindung zum Kartenleser beendet");
                Logging.WriteException("CardReader_PCSC", "ReadEGKPCSC", "Fehler beim Auslesen der Karte!", cex);
                return null;
            }
            catch (Exception ex)
            {
                Logging.WriteTracing("CardReader_PCSC", "ReadEGKPCSC", "Verbindung zum Kartenleser beendet");
                Logging.WriteException("CardReader_PCSC", "ReadEGKPCSC", "Fehler beim Auslesen der Karte!", ex);
                return null;
            }
        }
        /// <summary>
        /// Prüft ob eine Karte im Kartenslot steckt
        /// </summary>
        /// <returns>true: Karte steckt, false: keine Karte gefunden</returns>
        /// <remarks>
        /// pm20160714 Erstellung - Hinzugefügt um so im Client eine Warnung bei gesteckter Karte bei Maskenwechsel auszugeben
        /// </remarks>
        public bool checkCardInserted()
        {
            try
            {
                using (SCardContext context = new SCardContext())
                {
                    context.Establish(SCardScope.System);
                    var readerNames = context.GetReaders();
                    if ((readerNames != null))
                    {
                        if (readerNames.Length > 0)
                        {
                            foreach (string readerName in readerNames)
                            {
                                //Checkt ob eine Karte vorhanden ist. Dazu Karten-ATR abfragen
                                if (context.GetReaderStatus(readerName).Atr.Length > 0 && context.GetReaderStatus(readerName).Atr.Length < 20)
                                {
                                    Logging.WriteInformation("CardReader_PCSC", "checkCardInserted", $"Länge: {context.GetReaderStatus(readerName).Atr.Length} |ATR: {BitConverter.ToString(context.GetReaderStatus(readerName).Atr)}");
                                    //Wenn vorhanden, dann return true
                                    return true;
                                }
                            }
                        }
                        else
                        {
                            return false;
                        }
                        //Ansonsten false bei nicht vorhandener Karte
                        return false;
                    }
                }
            }
            catch (CardException cex)
            {
                Logging.WriteException("CardReader_PCSC", "checkCardInserted", "Verbindungsprobleme beim Auslesen der Karte!", cex);
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "checkCardInserted", "Beim Prüfen ist ein Fehler aufgetreten!", ex);
            }
            return false;
        }

        /// <summary>
        /// Karte anfordern
        /// Request ICC1
        /// </summary>
        /// <param name="isoReader">Aktives SmartCardReader Objekt</param>
        /// <returns>true: Anfrage erfolgreich, false: Fehler bei Abfrage</returns>
        /// <remarks>
        /// pm20161014 Erstellung - Hinzugefügt um so off. Spezifikation der GEMATIK nachzukommen
        /// Mit diesem Kommando wird die Chipkarte angefordert. Nach Einführung der Chipkarte wird
        /// automatisch ein Reset durchgeführt. Der Timer T ist auf '01' (=1 Sekunde) zu setzen. Im
        /// L-Byte ist dann ebenfalls '01' (Length = 1 Byte) anzugeben.
        /// </remarks>
        private bool requestCard(PCSC.Iso7816.IsoReader isoReader)
        {
            try
            {
                //APDU: '20 12 01 00 01 xx'
                PCSC.Iso7816.CommandApdu apdu = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Extended, isoReader.ActiveProtocol);
                //Zurücksetzen
                apdu.CLA = 0x20;
                apdu.INS = 12;
                apdu.P1 = 0x1;
                apdu.P2 = 0x0;
                apdu.Le = 0x1;
                apdu.Data = new byte[] { 0x5 };
                Logging.WriteInformation("CardReader_PCSC", "requestCard", "Sende APDU -> " + BitConverter.ToString(apdu.ToArray()));
                var response = isoReader.Transmit(apdu);
                if (!Tools.IstLeerObj(response))
                {
                    //9000' = synchronous ICC presented, Reset successful
                    //6200' = Warning: no card presented within specified time
                    //6400' = Reset not successful
                    Logging.WriteInformation("CardReader_PCSC", "requestCard", "APDU gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "requestCard", "APDU gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "requestCard", "APDU gesendet, Antwort SW2:" + response.SW2.ToString());
                    return true;
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "requestCard", "APDU gesendet, KEINE Antwort erhalten!");
                    return false;
                }
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "requestCard", "Fehler beim Anfordern des Kartenlesers!", ex);
                return false;
            }
        }

        /// <summary>
        /// Karte auswerfen
        /// Eject ICC1
        /// </summary>
        /// <param name="isoReader">Aktives SmartCardReader Objekt</param>
        /// <returns>true: Anfrage erfolgreich, false: Fehler bei Abfrage</returns>
        /// <remarks>
        /// pm20161014 Erstellung - Hinzugefügt um so off. Spezifikation der GEMATIK nachzukommen
        /// Das Kommando steuert die Kontaktiereinheit und ggf. vorhandene Signalgeber. Der Timer T
        /// ist auf '01' (=1 Sekunde) zu setzen. Im L-Byte ist dann ebenfalls '01' (Length = 1 Byte)
        /// anzugeben. Gesetzte Indikatoren (LEDs und/oder akustisches Signal) werden nach
        /// Herausnahme der Karte bzw. nach Ablauf des Application Timers, wenn die Karte nicht
        /// entnommen wurde, gelöscht.
        /// </remarks>
        private bool ejectCard(PCSC.Iso7816.IsoReader isoReader)
        {
            try
            {
                //APDU: '20 15 01 00 01 xx'
                PCSC.Iso7816.CommandApdu apdu = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Extended, isoReader.ActiveProtocol);
                //Zurücksetzen
                apdu.Instruction = PCSC.Iso7816.InstructionCode.GetResponse;
                apdu.CLA = 0x20;
                apdu.INS = 15;
                apdu.P1 = 0x1;
                apdu.P2 = 0x0;
                apdu.Le = 0x1;
                apdu.Data = new byte[] { 0x5 };
                Logging.WriteInformation("CardReader_PCSC", "ejectCard", "Sende APDU -> " + BitConverter.ToString(apdu.ToArray()));
                var response = isoReader.Transmit(apdu);
                if (!Tools.IstLeerObj(response))
                {
                    //9000' = Command successful
                    //9001' = Command successful, card removed
                    //6200' = Warning: Card not removed within specified time
                    Logging.WriteInformation("CardReader_PCSC", "ejectCard", "APDU gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "ejectCard", "APDU gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "ejectCard", "APDU gesendet, Antwort SW2:" + response.SW2.ToString());
                    return true;
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "ejectCard", "APDU gesendet, KEINE Antwort erhalten!");
                    return false;
                }
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "ejectCard", "Fehler beim Auswerfen der Karte!", ex);
                return false;
            }
        }

        /// <summary>
        /// Kartenleser zurücksetzen
        /// Reset CT
        /// </summary>
        /// <param name="isoReader">Aktives SmartCardReader Objekt</param>
        /// <returns>true: Anfrage erfolgreich, false: Fehler bei Abfrage</returns>
        /// <remarks>
        /// pm20161014 Erstellung - Hinzugefügt um so off. Spezifikation der GEMATIK nachzukommen
        /// Mit diesem Kommando kann das CardTerminal auf Anwendungsebene zurückgesetzt
        /// werden. Chipkarten, falls eingeführt, werden ausgeworfen, Chipkarten-bezogene
        /// Speicherinhalte im CT gelöscht, eventuell eingeschaltete Indikatoren (LEDs) werden auf ihren
        /// Initialwert zurückgesetzt.
        /// </remarks>
        private bool resetCardreader(PCSC.Iso7816.IsoReader isoReader)
        {
            try
            {
                //APDU: '20 11 00 00 00'
                PCSC.Iso7816.CommandApdu apdu = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case1, isoReader.ActiveProtocol);
                //Zurücksetzen
                apdu.CLA = 0x20;
                apdu.INS = 11;
                apdu.P1 = 0x0;
                apdu.P2 = 0x0;
                Logging.WriteInformation("CardReader_PCSC", "resetCardreader", "Sende APDU -> " + BitConverter.ToString(apdu.ToArray()));
                var response = isoReader.Transmit(apdu);
                if (!Tools.IstLeerObj(response))
                {
                    //9000' = Reset successful
                    //6400' = Reset not successful
                    Logging.WriteInformation("CardReader_PCSC", "resetCardreader", "APDU gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "resetCardreader", "APDU gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "resetCardreader", "APDU gesendet, Antwort SW2:" + response.SW2.ToString());
                    return true;
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "resetCardreader", "APDU gesendet, KEINE Antwort erhalten!");
                    return false;
                }
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "resetCardreader", "Fehler beim Zurücksetzen des Kartenlesers!", ex);
                return false;
            }
        }


        #region "EGKRoot Auslesen (Allg. Karteninformation)"
        /// <summary>
        /// Das auf der EGK-Karte befindliche EGKROOT-Segment auswählen (dient als Vorbereitung für ReadBinary-Kommandos zum Lesen von EF.ATR/EF.VERSION)
        /// </summary>
        /// <param name="isoReader">Aktives SmartCardReader Objekt</param>
        /// <returns>true: Anfrage erfolgreich, false: Fehler bei Abfrage</returns>
        /// <remarks>
        /// pm20161014 Erstellung - Hinzugefügt um so zusätzliche Karteninformationen auszulesen (Pufferlängen, Kartenversion)
        /// Das Selektieren des EGKRoot erlaubt anschließend Zugriff auf die auszulesenden Container: EF.ATR (=PufferlängenInfos) sowie EF.Version (Kartengeneration-Info)
        /// Diese Infos wurden vor Oktober 2016 nicht ausgelesen, da für CEUS RD nicht relevant, aber für Debugging notendig (laut gematik) 
        /// </remarks>
        private bool selectEGKRoot(PCSC.Iso7816.IsoReader isoReader)
        {
            try
            {
                //Select EGK - Root: '00 A4 04 0C 07 D2 76 00 01 44 80 00' 
                Logging.WriteWarning("CardReader_PCSC", "selectEGKRoot", "selectEGKRoot wird ausgeführt");
                PCSC.Iso7816.CommandApdu apdu = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case4Extended, isoReader.ActiveProtocol);
                string[] tempApdu = _config[_configIndex].rootSelect.Split('-');
                apdu.CLA = byte.Parse(tempApdu[0], NumberStyles.HexNumber);
                apdu.Instruction = PCSC.Iso7816.InstructionCode.SelectFile;
                apdu.P1 = byte.Parse(tempApdu[2], NumberStyles.HexNumber);
                apdu.P2 = byte.Parse(tempApdu[3], NumberStyles.HexNumber);
                apdu.Le = byte.Parse(tempApdu[4], NumberStyles.HexNumber);
                if (tempApdu.Length > 5)
                {
                    apdu.Data = new byte[tempApdu.Length - 5];
                    for (var tempindex = 0; tempindex + 5 < tempApdu.Length; tempindex++)
                    {
                        apdu.Data[tempindex] = byte.Parse(tempApdu[tempindex + 5], NumberStyles.HexNumber);
                    }
                }
                //EGK Root auswählen:
                //    apdu.CLA = 0x0;
                //    apdu.Instruction = PCSC.Iso7816.InstructionCode.SelectFile;
                //    apdu.P1 = 0x4;
                //    apdu.P2 = 0xc;
                //    apdu.Le = 0x7;
                //    apdu.Data = new byte[] {
                //    0xd2,
                //    0x76,
                //    0x0,
                //    0x1,
                //    0x44,
                //    0x80,
                //    0x0
                //};
                Logging.WriteInformation("CardReader_PCSC", "selectEGKRoot", "Sende APDU -> " + BitConverter.ToString(apdu.ToArray()));
                var response = isoReader.Transmit(apdu);
                if (!Tools.IstLeerObj(response))
                {
                    //9000' = Command successful
                    //6A82' = Application not found or ATR/ Dir() data incorrect
                    Logging.WriteInformation("CardReader_PCSC", "selectEGKRoot", "APDU gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "selectEGKRoot", "APDU gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "selectEGKRoot", "APDU gesendet, Antwort SW2:" + response.SW2.ToString());
                    return true;
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "selectEGKRoot", "APDU gesendet, KEINE Antwort erhalten!");
                    return false;
                }
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "selectEGKRoot", "Fehler beim selektieren des EGKROOT Segmentes!", ex);
                return false;
            }
        }

        /// <summary>
        /// Kartengeneration der EGK-Karte auslesen
        /// </summary>
        /// <param name="isoReader">Aktives SmartCardReader Objekt</param>
        /// <returns>EGK-Kartengeneration (G1/G2..) der eingelesen EGK-Karte als String, bei Fehler Leerstring</returns>
        /// <remarks>
        /// pm20161014 Ersterstellung - Hinzugefügt um so zusätzliche Karteninformationen auszulesen (Kartenversion) -> Laut Doku enthält Record 2 die entscheidende Versionsinformation der Karte
        /// Es wird das EF.VERSION Segment ausgelesen.
        /// Hinweis: Die Versionsinformation wird im Format XXXYYYZZZZ BCD(Binary Coded Decimal)-gepackt gespeichert. Die Antwort 00 30 01 00 02 ist als Version 3.1.2 zu interpretieren
        /// Beispielantwort EF.Version Rec.2-Segment: 00 40 00 00 00  --> v.4.0.0 -> G2-Karte!
        /// Aus DOKU:
        /// G2:     4.0.0               , als Antwort: 00 40 00 00 00
        /// G1Plus: 3.0.0, 3.0.1, 3.0.3 , als Antwort: 00 30 00 00 00 oder 00 30 00 00 01 oder 00 30 00 00 03
        /// G1:     3.0.0, 3.0.2        , als Antwort: 00 30 00 00 00 oder 00 30 00 00 02
        /// </remarks>
        private string ReadEGKKartenversion(PCSC.Iso7816.IsoReader isoReader)
        {
            // Die zurückzugebende EGK-Kartenversion, z.B. 40 00 00 (=G2)
            string EGKKartenversion = string.Empty;

            //Ermitteln der Kartenversion/generation (G1/G2 etc. -> wird diese Unterstützt?!)
            try
            {
                //Lese EF.Version Rec.1 / Version der unterstützten eGK Spec.Teil 1
                //Dieses Record wird eigentlich nicht benötigt, hier aber der Vollständigkeithalber drinlassen...
                //00 B2 01 84 00  -> Antwort Beispiel: 00 40 00 00 00 
                PCSC.Iso7816.CommandApdu apduReadEFVersion1 = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Short, isoReader.ActiveProtocol);
                apduReadEFVersion1.CLA = 0x0;
                apduReadEFVersion1.Instruction = PCSC.Iso7816.InstructionCode.ReadRecord;
                apduReadEFVersion1.P1 = 0x1;
                apduReadEFVersion1.P2 = 0x84;
                apduReadEFVersion1.Le = 0x0;
                Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "Sende EF.Version1 APDU -> " + BitConverter.ToString(apduReadEFVersion1.ToArray()));
                var response = isoReader.Transmit(apduReadEFVersion1);
                if (!Tools.IstLeerObj(response))
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version1 gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version1 gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version1 gesendet, Antwort SW2:" + response.SW2.ToString());
                    Logging.WriteTesting("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version1 Daten: " + BitConverter.ToString(response.GetData()));
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version1 gesendet, KEINE Antwort erhalten!");
                }

                //Lese EF.Version Rec.2 / Version der unterstützten eGK Spec.Teil 2
                //00 B2 02 04 00 -> Antwort Beispiel: 00 40 00 00 00
                PCSC.Iso7816.CommandApdu apduReadEFVersion2 = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Short, isoReader.ActiveProtocol);
                apduReadEFVersion2.CLA = 0x0;
                apduReadEFVersion2.Instruction = PCSC.Iso7816.InstructionCode.ReadRecord;
                apduReadEFVersion2.P1 = 0x2;
                apduReadEFVersion2.P2 = 0x84;
                apduReadEFVersion2.Le = 0x0;
                Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "Sende EF.Version2 APDU -> " + BitConverter.ToString(apduReadEFVersion2.ToArray()));
                response = isoReader.Transmit(apduReadEFVersion2);
                if (!Tools.IstLeerObj(response))
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version2 gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version2 gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version2 gesendet, Antwort SW2:" + response.SW2.ToString());
                    var meinedaten = BitConverter.ToString(response.GetData());
                    Logging.WriteTesting("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version2 Daten: " + meinedaten);
                    //Nun EGK Kartenversion abgreifen
                    if (meinedaten.Count() > 4)
                    {
                        var lstmeinedaten = meinedaten.Split(Convert.ToChar("-")).ToList();
                        Logging.WriteInformation("CardReader_PCSC", "ReadKartenpuffer", "EF.Version2 APDU Daten - Länge des Byte Array: " + lstmeinedaten.Count.ToString());
                        string Versionsinfo = lstmeinedaten[1] + lstmeinedaten[2] + lstmeinedaten[4];
                        Logging.WriteTesting("CardReader_PCSC", "ReadKartenpuffer", "VersionInfo-Rohformat: " + Versionsinfo);
                        switch (Versionsinfo)
                        {
                            case "400000":
                                return "G2";
                            case "300000":
                                return "G1Plus/G2";
                            case "300001":
                                return "G1Plus";
                            case "300003":
                                return "G1Plus";
                            case "300002":
                                return "G2";
                            default:
                                return Versionsinfo;
                        }
                    }
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version2 gesendet, KEINE Antwort erhalten!");
                }

                // Dieses Record wird eigentlich nicht benötigt, hier aber der Vollständigkeithalber drinlassen...
                //Lese EF.Version Rec.3 / Version der unterstützten Speicherstrukturen
                //00 B2 03 04 00  -> Antwort Beispiel: 00 40 00 00 00
                PCSC.Iso7816.CommandApdu apduReadEFVersion3 = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Short, isoReader.ActiveProtocol);
                apduReadEFVersion3.CLA = 0x0;
                apduReadEFVersion3.Instruction = PCSC.Iso7816.InstructionCode.ReadRecord;
                apduReadEFVersion3.P1 = 0x3;
                apduReadEFVersion3.P2 = 0x84;
                apduReadEFVersion3.Le = 0x0;
                Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "Sende EF.Version3 APDU -> " + BitConverter.ToString(apduReadEFVersion3.ToArray()));
                response = isoReader.Transmit(apduReadEFVersion3);
                if (!Tools.IstLeerObj(response))
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version3 gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version3 gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version3 gesendet, Antwort SW2:" + response.SW2.ToString());
                    Logging.WriteTesting("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version3 Daten: " + BitConverter.ToString(response.GetData()));
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenversion", "EF.Version3 gesendet, KEINE Antwort erhalten!");
                }
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "ReadEGKKartenversion", "Fehler beim Lesen des EF.Version-Segments!", ex);
            }
            return EGKKartenversion;
        }

        /// <summary>
        /// Maximalen Antwortpuffer der EGK-Karte auslesen
        /// Lese EF.ATR
        /// </summary>
        /// <param name="isoReader">Aktives SmartCardReader Objekt</param>
        /// <returns>Den maximal zugelassene Speicher in Bytes für das Festhalten der APDU Anfragen, bei Fehler wird -1 zurückgegeben!</returns>
        /// <remarks>
        /// pm20161014 Ersterstellung - Hinzugefügt um so zusätzliche Karteninformationen auszulesen (Puffergröße)
        /// Es wird das EF.ATR Segment ausgelesen. Das Auslesen der EF.ATR dient der maximalen Antwortpuffer-Ermittlung
        /// Hinweis: 
        /// Eigentlich wird diese Angabe für CEUS RD nicht benötigt, da wir im Gegensatz zur Gematik NUR die freien Versicherungsdaten abrufen (welche in der Regel klein genug sind, also kleiner als MaxPuffer)
        /// MaxPuffer wird interessant, wenn auch gleichzeitig die geschützten Daten ausgelesen werden, da dann sehr oft MaxBuffer in der APUD Anfrage überschritten werden würde (--> also dann Auslesen in 2 Schritte: 1.Durchgang Abfrage mit MaxPuffer im LE Element, 2.Durchgang: LE enthält Restlänge)
        /// </remarks>
        private int ReadEGKKartenpuffer(PCSC.Iso7816.IsoReader isoReader)
        {
            int maximaleAntwortLaenge = -1;
            try
            {
                //Lese EF.ATR
                //00 B0 9D 00 00 
                PCSC.Iso7816.CommandApdu apduReadEFATR = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Short, isoReader.ActiveProtocol);
                apduReadEFATR.CLA = 0x0;
                apduReadEFATR.Instruction = PCSC.Iso7816.InstructionCode.ReadBinary;
                apduReadEFATR.P1 = 0x9d;
                apduReadEFATR.P2 = 0x0;
                apduReadEFATR.Le = 0x0;
                Logging.WriteInformation("CardReader_PCSC", "ReadKartenpuffer", "Sende APDU -> " + BitConverter.ToString(apduReadEFATR.ToArray()));
                var response = isoReader.Transmit(apduReadEFATR);
                //Pufferlänge ermitteln
                //Beispiel:
                // Die Datei EF.ATR hat den Inhalt
                //'E0 10 02 02 01 23 02 02 02 34 02 02 04 56 02 02 07 89 ....'
                //Hier ist die maximale Länge der Antwortdaten mit '0234' = 564 Byte angegeben. Ein
                //“Read” darf demzufolge maximal 562 Byte als erwartete Datenlänge anfordern. (maximaleAntwortLaenge  - 2)
                if (!Tools.IstLeerObj(response))
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenpuffer", "APDU gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenpuffer", "APDU gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenpuffer", "APDU gesendet, Antwort SW2:" + response.SW2.ToString());
                    Logging.WriteTesting("CardReader_PCSC", "ReadEGKKartenpuffer", "APDU Daten: " + BitConverter.ToString(response.GetData()));
                    var meinedaten = BitConverter.ToString(response.GetData());
                    //Das zweite Datenobjekt enthält die maximal Pufferlänge für Antworten auf APDU Kommandos -daher hier festhalten!
                    if (!Tools.IstLeerObj(meinedaten) && meinedaten.Count() > 12)
                    {
                        var lstmeinedaten = meinedaten.Split(Convert.ToChar("-")).ToList();
                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKKartenpuffer", "APDU Daten - Länge des Byte Array: " + lstmeinedaten.Count.ToString());
                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKKartenpuffer", "APDU Daten - Länge des Byte Array: " + meinedaten);
                        string hexTeil1 = lstmeinedaten[12];
                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKKartenpuffer", "APDU Daten - Länge des Byte Array: " + hexTeil1);
                        string hexTeil2 = lstmeinedaten[13];
                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKKartenpuffer", "APDU Daten - Länge des Byte Array: " + hexTeil2);
                        Logging.WriteTesting("CardReader_PCSC", "ReadEGKKartenpuffer", "Puffergröße: " + hexTeil1 + hexTeil2);
                        maximaleAntwortLaenge = (System.Convert.ToInt32(hexTeil1 + hexTeil2, 16)) - 2;
                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKKartenpuffer", "Maximale zulässige Größe für Antwortdaten [Bytes]: " + maximaleAntwortLaenge.ToString());
                    }
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenpuffer", "APDU gesendet, KEINE Antwort erhalten!");
                }
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "ReadEGKKartenpuffer", "Fehler beim Lesen des EF.ATR-Segments!", ex);
            }
            return maximaleAntwortLaenge;
        }

        /// <summary>
        /// Versionskennung der EGK-XML-Schemadateien auslesen
        /// </summary>
        /// <param name="isoReader">Aktives SmartCardReader Objekt</param>
        /// <returns>EGK-CDM_Versionsnummer der eingelesen EGK-Karte als String, bei Fehler Leerstring</returns>
        /// <remarks>
        /// pm20161014 Ersterstellung - Hinzugefügt um so zusätzliche Karteninformationen auszulesen (VSD-Versioninformation der Schemadateien)
        /// Es wird das EF.StatusVD Segment ausgelesen.
        /// Dokuauszug:
        /// Schemaversionsnummer der in EF.VD, EF.PD und EF.GVD befindlichen Versichertenstammdaten. Dazu wird der Wert des Attributs CDM_VERSION (ist für alle drei Schemata immer gleich) im Format XXXYYYZZZZ
        /// eingetragen. Z. B. ist für die CDM_VERSION  (ist für alle drei Schemata immer gleich) im Format XXXYYYZZZZ eingetragen. Z. B. ist für die CDM_VERSION 7.3.1 der Wert 00 70 03 00 01 einzutragen
        /// Hinweis: 
        /// Im Moment nur genutzt um Version der Schemadateien auszugeben
        /// </remarks>
        private string ReadEGKKartenSchemaversion(PCSC.Iso7816.IsoReader isoReader)
        {
            // Die zurückzugebende EGK-Schemaversion, z.B. 500201 (=5.2.1)
            string EGKSchemaversion = string.Empty;
            try
            {
                //Lese EF.StatusVD
                //00 B0 8C 00 19 
                PCSC.Iso7816.CommandApdu apduReadEFATR = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Short, isoReader.ActiveProtocol);
                apduReadEFATR.CLA = 0x00;
                apduReadEFATR.Instruction = PCSC.Iso7816.InstructionCode.ReadBinary;
                apduReadEFATR.P1 = 0x8C;
                apduReadEFATR.P2 = 0x00;
                apduReadEFATR.Le = 0x19;
                Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenSchemaversion", "Sende APDU -> " + BitConverter.ToString(apduReadEFATR.ToArray()));
                var response = isoReader.Transmit(apduReadEFATR);
                if (!Tools.IstLeerObj(response))
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenSchemaversion", "APDU gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenSchemaversion", "APDU gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenSchemaversion", "APDU gesendet, Antwort SW2:" + response.SW2.ToString());
                    //Logging.WriteTesting("CardReader_PCSC", "ReadEGKKartenSchemaversion", "APDU Daten: " + BitConverter.ToString(response.GetData()));
                    try
                    {
                        var tmpbytes = response.GetData();
                        if (!Tools.IstLeerObj(tmpbytes) && tmpbytes.Length > 0)
                        {
                            var meinedaten = BitConverter.ToString(tmpbytes);
                            //Die Schemaversion steht ab Stelle 15 in der Antwort (aus Doku entnommen), daher ab dort Version abgreifen
                            //z.B ab Stelle 15: 00 70 03 00 01 --> CDM_VERSION 7.3.1
                            if (!Tools.IstLeerObj(meinedaten) && meinedaten.Count() > 19)
                            {
                                var lstmeinedaten = meinedaten.Split(Convert.ToChar("-")).ToList();
                                Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenSchemaversion", "APDU Daten - Länge des Byte Array: " + lstmeinedaten.Count.ToString());
                                EGKSchemaversion = lstmeinedaten[16] + lstmeinedaten[17] + lstmeinedaten[19];
                                Logging.WriteTesting("CardReader_PCSC", "ReadEGKKartenSchemaversion", "VSD Version: " + EGKSchemaversion);
                            }
                        }
                        else
                        {
                            Logging.WriteTesting("CardReader_PCSC", "ReadEGKKartenSchemaversion", "Keine auswertbare Antwort erhalten");
                        }
                    }
                    catch (Exception ex)
                    {
                        Logging.WriteException("CardReader_PCSC", "ReadEGKKartenSchemaversion", "Fehler beim Lesen der Schemaversion", ex);
                    }
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKKartenSchemaversion", "APDU gesendet, KEINE Antwort erhalten!");
                }
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "ReadEGKKartenSchemaversion", "Fehler beim Lesen des EF.StatusVD-Segments!", ex);
            }
            return EGKSchemaversion;
        }
        #endregion

        #region "HCA Auslesen (Patientendaten und Versichertendaten)"
        /// <summary>
        /// Das auf der EGK-karte befindliche HCA-Segment auswählen (dient als Vorbereitung für ReadBinary-Kommandos zum Lesen von PD,VD,VST)
        /// </summary>
        /// <param name="isoReader">Aktives SmartCardReader Objekt</param>
        /// <returns>true: HCA Bereich erfolgreich selektiert, false: Fehler beim Selektieren</returns>
        /// <remarks>
        /// pm20161014 Nun Function statt Sub um bei Fehlverhalten direkt das Auslesen zu Beenden! Außerdem Kommentare hinzugefügt (aus off. gematik Doku!)
        /// Erstellung von Janis L.
        /// </remarks>
        private bool selectHCA(PCSC.Iso7816.IsoReader isoReader)
        {
            try
            {
                //Auszug Doku: \\sid\team\Produkte\CEUS\CEUS-RD\1-Dokumentation\3-Schnittstellen\EGK\APDU_Schnittstellenbeschreibung.pdf
                //Das Kommando Select wählt die gewünschte Applikation, die die auszulesenden
                //Datencontainer enthält. Das Kommando selektiert für das Auslesen einer
                //gespeicherten eGK das Verzeichnis der ungeschützen Patientendaten. Eine KVK
                //enthält hingegen nur ein einziges Verzeichnis, das jedoch ebenfalls mit Select
                //vorher angewählt werden muß.
                //Das Select-Kommando unterscheidet sich in seiner APDU abhängig vom Typ des
                //aktuell aktivierten Datensatzes, KVK oder eGK.
                //Das Primärsystem kann anhand des Rückgabewertes des zuvor gesendeten
                //RequestICC (siehe Kap. 8.2) entscheiden, ob der aktuell selektierte Datensatz eine
                //KVK oder ein eGK repräsentiert und so die entsprechende APDU senden.
                //Im Falle eines KVK-Datensatzes muss das Select-Kommando wie folgt aufgebaut
                //sein:
                //CLA INS P1 P2 Lc Daten (AID KVK)
                //00  A4  04 00 06 D2 76 00 00 01 01

                //Für einen eGK-Datensatz lautet das Select-Kommando
                //CLA INS P1 P2 Lc Daten (AID eGK)
                //00  A4  04 0c 06 D2 76 00 00 01 02

                //Bei erfolgreicher Abarbeitung antwortet das medMobile mit
                //SW1 SW2
                //90 00 Kommando erfolgreich

                //Quelle: APDU Befehle aus Dokument: Implementierungsleitfaden zur Einbindung der eGK in die Primärsysteme der Leistungserbringer(), Seite 26, Kapitel: 
                //Beispiel:Select EGK - Root (n
                // '00 A4 04 0C 07 D2 76 00 01 44 80 00' 
                //Beispiel: Select HCA 
                // '00 A4 04 0C 06 D2 76 00 00 01 02' 
                //Die Dateien EF.PD und EF.VD müssen nach der Selektion der HCA nicht explizit selek-
                //tiert  werden,  da  es  eine  Variante  des  Lesekommandos  gibt,  mit  der  eine  Datei  implizit  
                //anhand der SFID ausgewählt wird. 

                //HCA auswählen:
                //00 A4 04 0C 06 D2 76 00 00 01 02'
                PCSC.Iso7816.CommandApdu apduSelectHCA = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case3Short, isoReader.ActiveProtocol);
                apduSelectHCA.CLA = 0x0;
                apduSelectHCA.Instruction = PCSC.Iso7816.InstructionCode.SelectFile;
                apduSelectHCA.P1 = 0x4;
                apduSelectHCA.P2 = 0xc;
                apduSelectHCA.Data = new byte[] {
                0xd2,
                0x76,
                0x0,
                0x0,
                0x1,
                0x2
            };
                Logging.WriteInformation("CardReader_PCSC", "selectHCA", "Sende APDU -> " + BitConverter.ToString(apduSelectHCA.ToArray()));
                var response = isoReader.Transmit(apduSelectHCA);
                if (!Tools.IstLeerObj(response))
                {
                    Logging.WriteInformation("CardReader_PCSC", "selectHCA", "APDU  gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "selectHCA", "APDU  gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "selectHCA", "APDU  gesendet, Antwort SW2:" + response.SW2.ToString());
                    return true;
                }
                else
                {
                    Logging.WriteInformation("CardReader_PCSC", "selectHCA", "APDU  gesendet, KEINE Antwort erhalten!");
                    return false;
                }

            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "selectHCA", "Fehler beim selektieren des HCA Segmentes!", ex);
                return false;
            }
        }


        /// <summary>
        /// Patientendaten der EGK-Karte auslesen
        /// </summary>
        /// <param name="isoReader">Aktives SmartCardReader Objekt</param>
        /// <returns>XML-Inhalt der Patientendatei als Stream, bei Fehler Nothing</returns>
        /// <remarks>
        /// pm20161014 Ersterstellung/Fehlerhandling hinzugefügt 
        /// Es wird das EF.PD Segment ausgelesen.
        /// Zunächst ist die Länge des Segments zu ermitteln, anschließend wird der Inhalt in ein ByteArray eingelesen (=GZIP) und entpackt
        /// </remarks>
        private System.IO.MemoryStream ReadEGKPatientendaten(PCSC.Iso7816.IsoReader isoReader, int MaxBufferSize)
        {
            //Die zurückzugebenden Patientendaten als Stream
            System.IO.MemoryStream EGKPatientendaten = null;

            try
            {
                //Die Antwortdaten im ByteArray
                byte[] ResponseBytes = new byte[] { };
                //Antwortobjekt, gnutzt für APDU-Anfragen
                PCSC.Iso7816.Response response = null;
                //Die zurückgegebene Größe des Datencontainers - Information ist wichtig um komplette Daten abzufragen
                int PDDateiaenge = -1;
                byte[] PDSizeRepsonse = null;
                //Lese Länge PD aus EF.PD
                //Zunächst ist die Länge der Daten zu ermitteln (P1='81’; die Länge steht in den ersten zwei Bytes (Le=02) im File) --> In der Regel gibt das  0x016F zurück
                //Kommando:
                //CLA INS P1 P2 Le
                //00  B0  81 00 02
                PCSC.Iso7816.CommandApdu apduReadLAENGEPD = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Short, isoReader.ActiveProtocol);
                apduReadLAENGEPD.CLA = 0x0;
                apduReadLAENGEPD.Instruction = PCSC.Iso7816.InstructionCode.ReadBinary;
                apduReadLAENGEPD.P1 = 0x81;
                apduReadLAENGEPD.P2 = 0x0;
                apduReadLAENGEPD.Le = 0x2;
                Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Sende Länge PD APDU -> " + BitConverter.ToString(apduReadLAENGEPD.ToArray()));
                response = isoReader.Transmit(apduReadLAENGEPD);
                if (!Tools.IstLeerObj(response))
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Länge PD APDU gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Länge PD gesendet, Antwort SW1:" + response.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Länge PD gesendet, Antwort SW2:" + response.SW2.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Länge PD Daten: " + BitConverter.ToString(response.GetData()));
                    PDSizeRepsonse = response.GetData();
                    PDDateiaenge = System.Convert.ToInt32(BitConverter.ToString(response.GetData()).Replace("-", ""), 16);
                    Logging.WriteTesting("CardReader_PCSC", "ReadEGKPatientendaten", "Länge PD: " + PDDateiaenge.ToString());
                }
                else
                {
                    Logging.WriteWarning("CardReader_PCSC", "ReadEGKPatientendaten", "Länge PD gesendet, KEINE Antwort erhalten! Auslesen der Patientendaten nicht möglich!");
                }

                //Falls Länge der PD-Daten erfolgreich ermittelt wurde, dann diese Länge für nächste Anfrage nutzen um die eigentlichen Patientendaten zu erhalten
                //Achtung: Länge darf MaxPufferAntwort nicht überschreiten sonstn gibts ein Problem beim Auslesen (bist jetzt war das aber nie der Fall!)
                if (!(PDDateiaenge == -1) && MaxBufferSize > PDDateiaenge)
                {
                    //Lese PD aus EF.PD
                    //Kommando:
                    //CLA INS P1 P2 Le
                    //00  B0  00 02 01 6F (Länge kommt aus vorheriger Ermittlung!)
                    PCSC.Iso7816.CommandApdu apduReadPD = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Extended, isoReader.ActiveProtocol);
                    apduReadPD.CLA = 0x0;
                    apduReadPD.Instruction = PCSC.Iso7816.InstructionCode.ReadBinary;
                    apduReadPD.P1 = 0x0;
                    apduReadPD.P2 = 0x2;
                    apduReadPD.Le = PDDateiaenge;
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Sende GETPD APDU -> " + BitConverter.ToString(apduReadPD.ToArray()));
                    response = isoReader.Transmit(apduReadPD);
                    if (!Tools.IstLeerObj(response))
                    {
                        Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "GETPD APDU gesendet, Antwort erhalten!");
                        Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "GETPD gesendet, Antwort SW1:" + response.SW1.ToString());
                        Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "GETPD gesendet, Antwort SW2:" + response.SW2.ToString());
                        ResponseBytes = response.GetData();
                        Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "GETPD Daten: " + BitConverter.ToString(response.GetData()));
                    }
                    else
                    {
                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKPatientendaten", "GETPD gesendet, KEINE Antwort erhalten! Auslesen der Patientendaten nicht möglich!");
                    }
                }
                else
                {
                    Logging.WriteWarning("CardReader_PCSC", "ReadEGKPatientendaten", string.Format("MaxBufferSize für Antwort ist mit {0} Bytes KLEINER als Größe der Patientendaten({1} Bytes) - Auslesen der Patientendaten ist in der derzeitigen Implementierung so nicht möglich!", MaxBufferSize, PDDateiaenge));
                }

                //Lese PD aus EF.PD - maximal 256 Bytes lesen - Case2Short statt Extended (Hinweis von Gematik um Firmwareprobleme zu umgehen bzw. Zum Debuggen da anscheinend nicht jeder Kartentreiber mit ExtendedLength Option zurechtkommt?!)
                //pm20161017 Deaktiviert, da doch nicht nötig
                //response = Nothing
                //Dim apduReadPDShort As New PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Short, isoReader.ActiveProtocol)
                //apduReadPDShort.CLA = &H0
                //apduReadPDShort.Instruction = PCSC.Iso7816.InstructionCode.ReadBinary
                //apduReadPDShort.P1 = &H0
                //apduReadPDShort.P2 = &H2
                //apduReadPDShort.Le = 256 'nur noch 256 Bytes lesen statt der realen Containerlänge!
                //Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Sende GETPD max256 APDU -> " + BitConverter.ToString(apduReadPDShort.ToArray()))
                //response = isoReader.Transmit(apduReadPDShort)
                //If Not Tools.IstLeerObj(response) Then
                //    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "GETPDmax256 APDU gesendet, Antwort erhalten!")
                //    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "GETPDmax256 gesendet, Antwort SW1:" & response.SW1.ToString)
                //    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "GETPDmax256 gesendet, Antwort SW2:" & response.SW2.ToString)
                //    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "GETPDmax256 Daten: " + BitConverter.ToString(response.GetData()))
                //Else
                //    Logging.WriteWarning("CardReader_PCSC", "ReadEGKPatientendaten", "GETPDmax256 gesendet, KEINE Antwort erhalten!")
                //End If

                //Starte unzip
                string antwortstring = BitConverter.ToString(response.GetData());
                string newData = string.Empty;
                //Den festen Kenner zu Beginn der Antwort entfernen (falls vorhanden), da dies noch nicht zum GZIP Inhalt gehört!
                if (antwortstring.Contains("1F-8B-08-00"))
                {
                    newData = antwortstring.Substring(antwortstring.IndexOf("1F-8B-08-00"));
                    byte[] data = new byte[] { };
                    //Die ersten 4 Elemente in der Liste entfernen um Kenner zu entfernen
                    //data = ResponseBytes.Skip(4).Take(ResponseBytes.Count - 4).ToArray
                    //Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Bereinigtes Bytearray: " + BitConverter.ToString(data))
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Daten nach Säuberung: " + newData);
                    string[] newPDTemp = newData.Split('-');
                    byte[] pdData = new byte[newPDTemp.Length];
                    for (int i = 0; i <= pdData.Length - 1; i += +1)
                    {
                        pdData[i] = System.Convert.ToByte(newPDTemp[i], 16);
                    }
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Nach Säuberung: " + BitConverter.ToString(pdData));
                    EGKPatientendaten = UnzipData(pdData);
                }
                else
                {
                    EGKPatientendaten = UnzipData(ResponseBytes);
                }

            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "ReadEGKPatientendaten", "Fehler beim Lesen der Patientendaten!", ex);
            }
            return EGKPatientendaten;
        }

        /// <summary>
        /// Versichertendaten der EGK-Karte auslesen
        /// </summary>
        /// <param name="isoReader">Aktives SmartCardReader Objekt</param>
        /// <returns>XML-Inhalt der Patientendatei als Stream, bei Fehler Nothing</returns>
        /// <remarks>
        /// pm20161014 Ersterstellung/Fehlerhandling hinzugefügt 
        /// Es wird das EF.VD Segment ausgelesen.
        /// Zunächst ist die Länge des Segments zu ermitteln, anschließend wird der Inhalt in ein ByteArray eingelesen (=GZIP) und entpackt
        /// Doku:
        /// Solange noch keine Authentisierung der eGK mit einem Heilberufsausweis oder einer Institutionskarte möglich ist, befindet sich eine Kopie der geschützten Daten (GVD) im
        /// ungeschützten Bereich, d.h.in der Datei EF.VD befinden sich zwei gepackte XMLDokumente. Sie müssen nicht notwendig unmittelbar hintereinander liegen. Start- und Ende-Offsets für beide Dokumente sind in den ersten 8 Bytes der Datei EF.VD eingetragen.
        /// </remarks>
        private System.IO.MemoryStream ReadEGKVersichertendaten(PCSC.Iso7816.IsoReader isoReader, int MaxBufferSize)
        {
            //Die zurückzugebenden Patientendaten als Stream
            System.IO.MemoryStream EGKVersichertendaten = null;

            try
            {
                //Die Antwortdaten im ByteArray
                byte[] ResponseBytes = new byte[] { };
                //Antwortobjekt, gnutzt für APDU-Anfragen
                PCSC.Iso7816.Response response = null;

                //pm20161017 NEU, da laut Gematik empfohlen: Zunächst Zeiger auslesen um Offset-Werte zu erhalten (Anfang/Ende der 2 Container auf EF.VD: Versichertendaten (frei) und GDV(geschützter Bereich))
                PCSC.Iso7816.Response responseReadZeigerVD = null;
                int VDContainerBeginnPosition = -1;
                int VDContainerEndePosition = -1;
                int GDVContainerBeginnPosition = -1;
                int GDVContainerEndePosition = -1;

                //Lese Zeiger aus EF.VD  
                //-> Antwort Beispiel: 00 08 01 A3 01 A4 02 7D 90 00  --> d.h. 
                //Offset VD Start=00 08  -> Stelle 8
                //Offset VD Ende=01 A3   -> Stelle 419
                //Offset GDV Start=01 A4 -> Stelle 420
                //Offset GDV Ende=02 7D  -> Stelle 637
                //Kommando:
                //CLA INS P1 P2 Le
                //00  B0  82 00 08
                PCSC.Iso7816.CommandApdu apduReadZeigerVD = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Short, isoReader.ActiveProtocol);
                apduReadZeigerVD.CLA = 0x0;
                apduReadZeigerVD.Instruction = PCSC.Iso7816.InstructionCode.ReadBinary;
                apduReadZeigerVD.P1 = 0x82;
                apduReadZeigerVD.P2 = 0x0;
                apduReadZeigerVD.Le = 0x8;
                Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "Sende ZeigerVD APDU -> " + BitConverter.ToString(apduReadZeigerVD.ToArray()));
                responseReadZeigerVD = isoReader.Transmit(apduReadZeigerVD);
                if (!Tools.IstLeerObj(responseReadZeigerVD))
                {
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "ZeigerVD APDU gesendet, Antwort erhalten!");
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "ZeigerVD gesendet, Antwort SW1:" + responseReadZeigerVD.SW1.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "ZeigerVD gesendet, Antwort SW2:" + responseReadZeigerVD.SW2.ToString());
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "ZeigerVD Daten: " + BitConverter.ToString(responseReadZeigerVD.GetData()));
                    var meinedaten = BitConverter.ToString(responseReadZeigerVD.GetData());
                    if (!Tools.IstLeerObj(meinedaten))
                    {
                        Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "ZeigerVD Daten - Länge des Byte Array: " + meinedaten.Length.ToString());
                        //Offset Wert(e) (Positionen der beiden Container) aus Antwort auslesen
                        var lstmeinedaten = meinedaten.Split(Convert.ToChar("-")).ToList();
                        //Grenzen VD-Bereich:
                        if (meinedaten.Count() > 3)
                        {
                            Logging.WriteTesting("CardReader_PCSC", "ReadEGKVersichertendaten", string.Format("StartVD:{0}|EndeVD:{1}", lstmeinedaten[0] + lstmeinedaten[1], lstmeinedaten[2] + lstmeinedaten[3]));
                            VDContainerBeginnPosition = System.Convert.ToInt32(lstmeinedaten[0] + lstmeinedaten[1], 16);
                            VDContainerEndePosition = System.Convert.ToInt32(lstmeinedaten[2] + lstmeinedaten[3], 16);
                        }
                        else
                        {
                            Logging.WriteWarning("CardReader_PCSC", "ReadEGKVersichertendaten", "VD-Bereich ist nicht korrekt definiert! Auslesen der Versichertendaten nicht möglich!");
                        }
                        //Grenzen GDV-Bereich:
                        if (meinedaten.Count() > 6)
                        {
                            Logging.WriteTesting("CardReader_PCSC", "ReadEGKVersichertendaten", string.Format("StartGVD:{0}|EndeGVD:{1}", lstmeinedaten[4] + lstmeinedaten[5], lstmeinedaten[6] + lstmeinedaten[7]));
                            GDVContainerBeginnPosition = System.Convert.ToInt32(lstmeinedaten[4] + lstmeinedaten[5], 16);
                            GDVContainerEndePosition = System.Convert.ToInt32(lstmeinedaten[6] + lstmeinedaten[7], 16);
                        }
                        else
                        {
                            Logging.WriteWarning("CardReader_PCSC", "ReadEGKVersichertendaten", "GDV-Bereich ist korrekt definiert.");
                        }
                    }
                    else
                    {
                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKVersichertendaten", "ZeigerVD Daten ist leer! Auslesen der Versichertendaten nicht möglich!");
                    }
                }
                else
                {
                    Logging.WriteWarning("CardReader_PCSC", "ReadEGKVersichertendaten", "ZeigerVD gesendet, KEINE Antwort erhalten! Auslesen der Versichertendaten nicht möglich!");
                }

                //Falls Grenzen der VD-Daten erfolgreich ermittelt wurden, dann diese Angaben für nächste Anfrage nutzen um die eigentlichen Daten zu erhalten
                //Achtung: Containergröße darf MaxPufferAntwort nicht überschreiten sonstn gibts ein Problem beim Auslesen (bist jetzt war das aber nie der Fall!)
                if (!(VDContainerBeginnPosition == -1) && !(VDContainerEndePosition == -1) && (MaxBufferSize > (VDContainerEndePosition - VDContainerBeginnPosition)))
                {
                    //Lese VD aus EF.VD 
                    //Kommando:
                    //CLA INS P1 P2 Le
                    //00  B0  00 08 (Ende-Beginn des Containers)
                    PCSC.Iso7816.CommandApdu apduReadVD = new PCSC.Iso7816.CommandApdu(PCSC.Iso7816.IsoCase.Case2Extended, isoReader.ActiveProtocol);
                    apduReadVD.CLA = 0x0;
                    apduReadVD.Instruction = PCSC.Iso7816.InstructionCode.ReadBinary;
                    apduReadVD.P1 = 0x0;
                    apduReadVD.P2 = 0x8;
                    // ist das wirklich immer fest? Eventuell besser mit VDContainerBeginnPosition setzen??
                    apduReadVD.Le = VDContainerEndePosition - VDContainerBeginnPosition;
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "Sende VD APDU -> " + BitConverter.ToString(apduReadVD.ToArray()));
                    response = isoReader.Transmit(apduReadVD);
                    if (!Tools.IstLeerObj(response))
                    {
                        Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "VD APDU gesendet, Antwort erhalten!");
                        Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "VD gesendet, Antwort SW1:" + response.SW1.ToString());
                        Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "VD gesendet, Antwort SW2:" + response.SW2.ToString());
                        ResponseBytes = response.GetData();
                        Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "VD Daten: " + BitConverter.ToString(response.GetData()));
                    }
                    else
                    {
                        Logging.WriteWarning("CardReader_PCSC", "ReadEGKVersichertendaten", "VD gesendet, KEINE Antwort erhalten!");
                    }
                }
                else
                {
                    Logging.WriteWarning("CardReader_PCSC", "ReadEGKVersichertendaten", string.Format("MaxBufferSize für Antwort ist mit {0} Bytes KLEINER als Größe der freien Versichertendaten({1} Bytes) - Auslesen der Versichertendaten ist in der derzeitigen Implementierung so nicht möglich!", MaxBufferSize, (VDContainerEndePosition - VDContainerBeginnPosition)));
                }

                //Starte unzip
                string antwortstring = BitConverter.ToString(response.GetData());
                string newData = string.Empty;
                //Den festen Kenner zu Beginn der Antwort entfernen (falls vorhanden), da dies noch nicht zum GZIP Inhalt gehört!
                if (antwortstring.StartsWith("1F-8B-08-00"))
                {
                    //Dim data() As Byte = New Byte() {}
                    //'Die ersten 4 Elemente in der Liste entfernen um Kenner zu entfernen
                    //data = ResponseBytes.Skip(4).Take(ResponseBytes.Count - 4).ToArray
                    //Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "Bereinigtes Bytearray: " + BitConverter.ToString(data))
                    //EGKVersichertendaten = UnzipData(data)
                    newData = antwortstring.Substring(antwortstring.IndexOf("1F-8B-08-00"));
                    byte[] data = new byte[] { };
                    //Die ersten 4 Elemente in der Liste entfernen um Kenner zu entfernen
                    //data = ResponseBytes.Skip(4).Take(ResponseBytes.Count - 4).ToArray
                    //Logging.WriteInformation("CardReader_PCSC", "ReadEGKPatientendaten", "Bereinigtes Bytearray: " + BitConverter.ToString(data))
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "Daten nach Säuberung: " + newData);
                    string[] newVDTemp = newData.Split('-');
                    byte[] vdData = new byte[newVDTemp.Length];
                    for (int i = 0; i <= vdData.Length - 1; i += +1)
                    {
                        vdData[i] = System.Convert.ToByte(newVDTemp[i], 16);
                    }
                    Logging.WriteInformation("CardReader_PCSC", "ReadEGKVersichertendaten", "Nach Säuberung: " + BitConverter.ToString(vdData));
                    EGKVersichertendaten = UnzipData(vdData);
                }
                else
                {
                    EGKVersichertendaten = UnzipData(ResponseBytes);
                }

            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "ReadEGKVersichertendaten", "Fehler beim Lesen der Versichertendaten!", ex);
            }
            return EGKVersichertendaten;
        }

        /// <summary>
        /// Aus Streamdaten von Patientendaten/Versichertendaten ein valides Dictionary zurückgeben, welches von Client ausgewertet werden kann
        /// </summary>
        /// <param name="pd_xml">Patientendaten</param>
        /// <param name="vd_xml">Versichertendaten</param>
        /// <returns>Gefülltes Dictionary aus Karteninformationen, bei Fehler Nothing</returns>
        /// <remarks>
        /// Diese Funktion wurde blind aus bestehnder Klasse Cardreader übernommen - ist allgemeingültig
        /// </remarks>
        private CardReader.CardData operateData(MemoryStream pd_xml, MemoryStream vd_xml)
        {
            try
            {
                string strPersonendaten = ReadFromMemoryStreamToString(pd_xml);
                //Entfernt Bad Charakter aus String bevor mit ReadXml eingelesen wird, da sonst Fehler!
                string byText = strPersonendaten;
                string strText = byText;
                int strlen = strText.IndexOf(((char)0).ToString());
                if (strlen != -1)
                {
                    strText = strText.Substring(0, strlen - 1);
                }
                string strText2 = strText;
                strText2 = RemoveLineEndings(strText2);
                Logging.WriteInformation("CardReader_PCSC", "operateData", strText2);
                //pm20111124 Fügt Endtag hinzu (für alte EGK Karten)
                if (strText.Substring(strText.Length - 1).Equals("L"))
                {
                    // anstatt "/UC_PersoenlicheVersichertendatenXML" besser nach "UC_PersoenlicheVersichertendatenXML" suchen, da es auch manchmal auch so auf Karte gespeichert ist:  "</ vsd:UC_PersoenlicheVersichertendatenXML"
                    strText2 = strText.Replace("</UC_PersoenlicheVersichertendatenXML", "</UC_PersoenlicheVersichertendatenXML>");
                    strText2 = strText.Replace(":UC_PersoenlicheVersichertendatenXML", ":UC_PersoenlicheVersichertendatenXML>");
                }
                DataSet pd_ds = new DataSet();
                if (!Tools.IstLeerObj(pd_xml))
                {
                    try
                    {
                        if (strText.Substring(strText.Length - 1).Equals("L"))
                        {
                            Logging.WriteWarning("CardReader_PCSC", "operateData", "PersoenlicheVersichertendaten-XML: " + strText2);
                            pd_ds.ReadXml(pd_xml);
                            Logging.WriteTracing("CardReader_PCSC", "operateData", "PersoenlicheVersichertendaten-XML aus Stream eingelesen.");
                        }
                        else
                        {
                            Logging.WriteInformation("CardReader_PCSC", "operateData", "Führe XmlReader mit folgendem String " + strText2 + " aus.");
                            XmlReader xReader = XmlReader.Create(new StringReader(strText2));
                            pd_ds.ReadXml(xReader);
                            Logging.WriteTracing("CardReader_PCSC", "operateData", "PersoenlicheVersichertendaten per XmlReader eingelesen.");
                        }
                    }

                    catch (Exception ex1)
                    {
                        Logging.WriteException("CardReader_PCSC", "operateData", "Fehler beim Einlesen der Persönlichen VErsichertendaten!", ex1);
                    }
                }
                else
                {
                    return null;
                }

                //pm20111123 Liest String aus Memorystream zum weiteren Bearbeiten der Kartendaten vor Einlesen in Dataset mittels ReadXML
                string strVersichertendaten = ReadFromMemoryStreamToString(vd_xml);
                //Entfernt Bad Charakter aus String bevor mit ReadXml eingelesen wird, da sonst Fehler!
                strText = strVersichertendaten;
                strlen = strText.IndexOf(((char)0).ToString());
                if (strlen != -1)
                {
                    strText = strText.Substring(0, strlen - 1);
                }

                strText2 = strText;
                strText2 = RemoveLineEndings(strText2);
                Logging.WriteInformation("CardReader_PCSC", "operateData", strText2);
                //pm20111124 Fügt Endtag hinzu (für alte EGK Karten)
                if (strText.Substring(strText.Length - 1).Equals("L"))
                {
                    strText2 = strText.Replace("/UC_AllgemeineVersicherungsdatenXML", "/UC_AllgemeineVersicherungsdatenXML>");
                    strText2 = strText.Replace(":UC_AllgemeineVersicherungsdatenXML", ":UC_AllgemeineVersicherungsdatenXML>");
                }

                DataSet vd_ds = new DataSet();
                if (!Tools.IstLeerObj(vd_xml))
                {
                    try
                    {
                        if (strText.Substring(strText.Length - 1).Equals("L"))
                        {
                            Logging.WriteInformation("CardReader_PCSC", "operateData", "Versicherungsdaten-XML: " + strText2);
                            vd_ds.ReadXml(vd_xml);
                            Logging.WriteTracing("CardReader_PCSC", "operateData", "Versicherungsdaten-XML aus Stream eingelesen.");
                        }
                        else
                        {
                            Logging.WriteInformation("CardReader_PCSC", "operateData", "Führe XmlReader mit folgendem String " + strText2 + " aus.");
                            XmlReader xReader = XmlReader.Create(new StringReader(strText2));
                            vd_ds.ReadXml(xReader);
                            Logging.WriteTracing("CardReader_PCSC", "operateData", "Versicherungsdaten per XmlReader eingelesen.");
                        }
                    }

                    catch (Exception ex2)
                    {
                        Logging.WriteException("CardReader_PCSC", "operateData", "Fehler beim Einlesen der Allgemeinen Versichertendaten!", ex2);
                    }
                }
                else
                {
                    return null;
                }

                CardReader.CardData carddata = new CardReader.CardData();
                if ((pd_ds != null) && (vd_ds != null))
                {
                    Logging.WriteInformation("CardReader_PCSC", "operateData", "Dateien sind gefüllt");

                    //pm20111115 Zum Testen/Erfassen der gespeicherten Daten auf der Karte in lokale Xml Datei
                    if (!Tools.IstLeerObj(Csx.Utilities.Utility.Configuration.GetSettings("CardWriteDataEGK", true, root)))
                    {
                        vd_ds.WriteXml("vd_xml.xml");
                        pd_ds.WriteXml("pd_xml.xml");
                    }
                    carddata = CreateReturnDict(pd_ds, vd_ds);
                    Logging.WriteInformation("CardReader_PCSC", "operateData", carddata.Name);
                }
                return carddata;
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "operateData", "Fehler beim Bilden des Dictionary!", ex);
                return null;
            }
        }
        #endregion

        /// <summary>
        /// ByteArray dekomprimieren und als (XML-)String zurückgeben
        /// </summary>
        /// <param name="dataBuffer"></param>
        /// <returns></returns>
        /// <remarks>
        /// Diese Funktion wurde blind aus bestehnder Klasse Cardreader übernommen - ist allgemeingültig
        /// </remarks>
        private System.IO.MemoryStream UnzipData(byte[] dataBuffer)
        {
            try
            {
                // Existiert die Datei überhaupt
                if (dataBuffer.Length > 0)
                {
                    // GZIP-Datei öffnen
                    System.IO.MemoryStream ms = new System.IO.MemoryStream(dataBuffer);
                    //ms.Seek(0, System.IO.SeekOrigin.Begin)
                    System.IO.Compression.GZipStream oCompress = new System.IO.Compression.GZipStream(ms, System.IO.Compression.CompressionMode.Decompress, false);

                    // Inhalt auslesen und dekomprimieren
                    byte[] buffer = new byte[10001];
                    int offset = 0;
                    int buffer_size = 100;
                    while (true)
                    {
                        int bytesRead = oCompress.Read(buffer, offset, buffer_size);
                        if (bytesRead == 0)
                        {
                            break; // TODO: might not be correct. Was : Exit While
                        }
                        offset += bytesRead;
                    }
                    oCompress.Close();
                    return new System.IO.MemoryStream(buffer);
                }
                else
                {
                    return null;
                }
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader_PCSC", "UnzipData", "Fehler beim Entpacken der Daten", ex);
                return null;
            }
        }
        public static string RemoveLineEndings(string value)
        {
            if (String.IsNullOrEmpty(value))
            {
                return value;
            }
            string tabSeparator = ((char)0x0009).ToString();
            string lineSeparator = ((char)0x2028).ToString();
            string paragraphSeparator = ((char)0x2029).ToString();
            var tempvalue = value.Replace("\r\n", string.Empty).Replace("\n", string.Empty).Replace("\r", string.Empty).Replace(lineSeparator, string.Empty).Replace(paragraphSeparator, string.Empty).Replace(tabSeparator, string.Empty);
            tempvalue = System.Text.RegularExpressions.Regex.Replace(tempvalue, "[ ]{2,}", string.Empty);
            return tempvalue;
        }
        public static string ReadFromMemoryStreamToString(System.IO.MemoryStream memStream, int startPos = 0)
        {
            // reset the stream or we'll get an empty string returned
            // remember the position so we can restore it later

            // TODO: Evtl. ist der Stream nicht immer vollständig?
            // Evtl. muss man hier noch eine "Sicherheitsschleife" herumbasteln?
            var Pos = memStream.Position;
            memStream.Position = startPos;

            System.IO.StreamReader reader = new System.IO.StreamReader(memStream, System.Text.Encoding.GetEncoding("ISO-8859-15"));

            var str = reader.ReadToEnd().Replace(Environment.NewLine, "");

            // reset the position so that subsequent writes are correct
            memStream.Position = Pos;

            return str;
        }
        public CardReader.CardData CreateReturnDict(DataSet pd, DataSet vd)
        {
            CardReader.CardData dict = new CardReader.CardData();
            try
            {
                // Speichern der gesamten Versicherungs-und Personendaten die auf der Karte sind als Dump/XML in String--> Steht als redundantes Feld zur Abfrage zur Verfügung
                dict.VersichertendatenGesamt = string.Empty;
                dict.PersonendatenGesamt = string.Empty;
                try
                {
                    StringWriter personendatenstream = new StringWriter();
                    pd.WriteXml(personendatenstream);
                    dict.PersonendatenGesamt = personendatenstream.ToString();
                }
                catch (Exception ex)
                {
                    Logging.WriteException("CardReader", "CreateReturnDict", "Fehler beim Speichern der gesamten Personendaten in String", ex);
                }

                try
                {
                    StringWriter versicherungsdatenstream = new StringWriter();
                    vd.WriteXml(versicherungsdatenstream);
                    dict.VersichertendatenGesamt = versicherungsdatenstream.ToString();
                }
                catch (Exception ex)
                {
                    Logging.WriteException("CardReader", "CreateReturnDict", "Fehler beim Speichern der gesamten Versicherungsdaten in String", ex);
                }
                // Füllen des dict mit Personendaten 
                dict.PKennummer = fillDictByXml(pd, _config[_configIndex].Versicherten_ID);
                dict.Name = fillDictByXml(pd, _config[_configIndex].Name);
                dict.Vorname = fillDictByXml(pd, _config[_configIndex].Vorname);
                dict.Geburtsdatum = fillDictByXml(pd, _config[_configIndex].Geburtsdatum);
                dict.Geschlecht = fillDictByXml(pd, _config[_configIndex].Geschlecht);
                dict.Titel = fillDictByXml(pd, _config[_configIndex].Titel);
                dict.Namenszusatz = fillDictByXml(pd, _config[_configIndex].Vorsatzwort);
                dict.PLZ = fillDictByXml(pd, _config[_configIndex].Postleitzahl);
                dict.Ort = fillDictByXml(pd, _config[_configIndex].Ort);
                dict.LKZ = fillDictByXml(pd, _config[_configIndex].Wohnsitzlaendercode);
                dict.Strasse = fillDictByXml(pd, _config[_configIndex].Strasse);
                dict.Hausnummer = fillDictByXml(pd, _config[_configIndex].Hausnummer);
                dict.Anschriftenzusatz = fillDictByXml(pd, _config[_configIndex].Anschriftenzusatz);
                // Füllen des dict mit Versicherungsdaten
                dict.Verfallsdatum = fillDictByXml(vd, _config[_configIndex].Ende);
                dict.Versicherungsnummer = (fillDictByXml(vd, _config[_configIndex].KostentraegerkennungAR) != string.Empty) ? fillDictByXml(vd, _config[_configIndex].KostentraegerkennungAR) : fillDictByXml(vd, _config[_configIndex].Kostentraegerkennung);
                dict.KKName = (fillDictByXml(vd, _config[_configIndex].KKNameAR) != string.Empty) ? fillDictByXml(vd, _config[_configIndex].KKNameAR) : fillDictByXml(vd, _config[_configIndex].KKName);
                dict.Status = fillDictByXml(vd, _config[_configIndex].Status);
                dict.Versichertenstatus_RSA = fillDictByXml(vd, _config[_configIndex].Versichertenstatus_RSA);
                dict.Statusergänzung = fillDictByXml(vd, _config[_configIndex].Statuserweiterung);

                return dict;
            }
            catch (Exception ex)
            {
                Logging.WriteException("CardReader", "CreateReturnDict", "Fehler beim Auslesen des Datasets", ex);
                return null;
            }
        }
        //Liest den Inhalt der languageCard.xml aus und schreibt dieses in _conifg
        private void ReadCardXmlConfig()
        {
            XmlDocument doc = new XmlDocument();
            doc.Load(root + "languageCard.xml");
            var xmlNodeList = doc.SelectNodes("//country");
            Logging.WriteInformation("CardReader_PCSC", "ReadCardXmlConfig", "Lese Apdu config ein");
            if (xmlNodeList == null) return;
            for (var index = 0; index < xmlNodeList.Count; index++)
            {
                _config.Add(new LanguageCardXmlConfig());
                XmlNode xn = xmlNodeList[index];
                if (!xn.HasChildNodes) continue;
                var atrListe = xn["ATRResponse"]?.ChildNodes;
                for (int atrindex = 0; atrindex < atrListe.Count; atrindex++)
                {
                    _config[index].Country.Add((atrListe.Item(atrindex).InnerText != null && atrListe.Item(atrindex).InnerText.Length > 0) ? atrListe.Item(atrindex).InnerText : string.Empty);
                }
                var apduListe = xn["apdus"]?.ChildNodes;
                for (int itemIndex = 0; itemIndex < apduListe.Count; itemIndex++)
                {
                    PropertyInfo property = _config[index].GetType().GetProperties()[itemIndex + 1];
                    _config[index].GetType().GetProperty(property.Name).SetValue(_config[index], xmlTagData(apduListe, itemIndex));
                    Logging.WriteInformation("CardReader_PCSC", "ReadCardXmlConfig", "PropertyName: " + property.Name + " Value: " + xmlTagData(apduListe, itemIndex));
                }
                var xmlTagListe = xn["xmlTags"]?.ChildNodes;
                for (int itemIndex = 0; itemIndex < xmlTagListe.Count; itemIndex++)
                {
                    PropertyInfo property = _config[index].GetType().GetProperties()[itemIndex + apduListe.Count + 1];
                    _config[index].GetType().GetProperty(property.Name).SetValue(_config[index], xmlTagData(xmlTagListe, itemIndex));
                    Logging.WriteInformation("CardReader_PCSC", "ReadCardXmlConfig", "PropertyName: " + property.Name + " Value: " + xmlTagData(xmlTagListe, itemIndex));
                }
            }
        }
        //Liest den Inhalt der Xmlliste beim angegebenen Index aus
        private string xmlTagData(XmlNodeList xmlTagListe, int index)
        {
            if (xmlTagListe?.Item(index) == null) return string.Empty;
            return xmlTagListe.Item(index).InnerText;
        }
        // Durchsucht das übergebene Dataset nach xmltags
        // Falls nicht gefunden wird ein empty String zurück gegeben
        private string fillDictByXml(DataSet ds, string xmlTag)
        {
            if (xmlTag.Length > 0 && xmlTag.Split('.').Length > 1)
            {
                if (ds.Tables.Contains(xmlTag.Split('.')[0]))
                {
                    if (ds.Tables[xmlTag.Split('.')[0]].Columns.Contains(xmlTag.Split('.')[1]))
                    {
                        return ds.Tables[xmlTag.Split('.')[0]].Rows[0][xmlTag.Split('.')[1]].ToString();
                    }
                }
            }
            return string.Empty;
        }
        // Sucht mit Hilfe des erhaltenen ATR die richtige config
        private Boolean CheckForAtr(string foundAtrResult)
        {
            for (int index = 0; index < _config.Count; index++)
            {
                Logging.WriteTracing("CardReader_PCSC", "CheckForAtr", "Index: " + index);
                if (_config[index].Country.Contains(foundAtrResult))
                {
                    Logging.WriteTracing("CardReader_PCSC", "CheckForAtr", "Index: " + foundAtrResult + " ist in config.Country");
                    _configIndex = index;
                    return true;
                }
            }
            return false;
        }

        private Boolean getRootSelect(PCSC.Iso7816.IsoReader isoReader)
        {
            if (_config[_configIndex].rootSelect != string.Empty)
            {
                Logging.WriteWarning("CardReader_PCSC", "getRootSelect", "selectEGKRoot wird aufgerufen");
                return selectEGKRoot(isoReader);
            }
            Logging.WriteWarning("CardReader_PCSC", "getRootSelect", "selectEGKRoot wurde ignoriert");
            return true;
        }
    }
}