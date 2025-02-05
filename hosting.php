<?php
// Fonction pour générer une chaîne aléatoire
function generateRandomString($length = 8) {
    $characters = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    $randomString = '';
    for ($i = 0; $i < $length; $i++) {
        $randomString .= $characters[rand(0, strlen($characters) - 1)];
    }
    return $randomString;
}

// Générer un ID et un mot de passe
$clientId = generateRandomString(8);
$clientPassword = generateRandomString(8);

// Afficher les résultats
?>
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Générer un ID et un Mot de Passe</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            background-color: #f4f4f4;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
        }
        .container {
            background-color: #fff;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 0 10px rgba(0, 0, 0, 0.1);
            text-align: center;
        }
        h1 {
            margin-bottom: 20px;
        }
        .credentials {
            margin-top: 20px;
        }
        .credentials p {
            font-size: 18px;
            margin: 10px 0;
        }
        .credentials strong {
            color: #007BFF;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Générer un ID et un Mot de Passe</h1>
        <form method="POST" action="">
            <button type="submit" name="generate">Générer</button>
        </form>

        <?php if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['generate'])): ?>
            <div class="credentials">
                <p>Votre ID de connexion : <strong><?php echo htmlspecialchars($clientId); ?></strong></p>
                <p>Votre mot de passe : <strong><?php echo htmlspecialchars($clientPassword); ?></strong></p>
            </div>
        <?php endif; ?>
    </div>
</body>
</html>